# 3a-v-a — history and blame: acceptance

**Spec:** [`2026-10-23-3a-v-conflicts-history-blame-design.md`](../superpowers/specs/2026-10-23-3a-v-conflicts-history-blame-design.md)
· **Plan:** [`2026-10-23-3a-v-a-history-and-blame.md`](../superpowers/plans/2026-10-23-3a-v-a-history-and-blame.md)

The exit criterion, from the spec: the operator reads a file's history in a Timeline under the Files
tab and opens any commit's change to it, and reads who last changed the cursor's line, when and why,
at the end of that line — VS Code's Timeline and inline blame; the agent reads both. No write is added.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the worktree root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run.

```bash
(
set -e
REPO="$(git rev-parse --show-toplevel)"
ORG=personal
W="$TMPDIR/walk-3a-v-a"
rm -rf "$W"
mkdir -p "$W/project" "$W/work"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
as() { n="$1"; shift; git -c user.name="$n" -c user.email="$(echo "$n" | tr 'A-Z ' 'a-z.')@example.com" "$@"; }
cd "$W/work"
git init -q -b main
printf 'alpha\nbeta\ngamma\n' > "old name.txt"
git add . && as "Ada Lovelace" commit -qm "Seed the search page"
git mv "old name.txt" search.txt && printf 'alpha\nBETA\ngamma\n' > search.txt
git add . && as "Grace Hopper" commit -qm "Rename to search"
printf 'alpha\nBETA\nGAMMA\n' > search.txt && as "Seed" commit -qam "Tune the search"
for i in $(seq 1 55); do echo "$i" >> log.txt; git add log.txt; as "Seed" commit -qm "Log $i"; done
cat > "$W/project/project.json" <<J
{"name":"walk-3a-v-a","org":"$ORG","roots":[{"path":"$W/work"}],"scopes":{},"environments":{}}
J
cd "$REPO"
./bin/wakil project rm walk-3a-v-a --org "$ORG" || true
./bin/wakil project add walk-3a-v-a --path "$W/project/project.json" --org "$ORG"
)
```

`work` has `search.txt`, added as `old name.txt` by Ada Lovelace, renamed (and line 2 changed) by
Grace Hopper, and line 3 changed by Seed; and `log.txt`, changed in 55 commits. Launch from the
worktree root with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil` and make `walk-3a-v-a`
active with ⌘P. Terminal commands run from any folder.

## 1. The walk

Each row is one thing to do. **Wakil** rows happen in the app; **Terminal** rows run in any folder on
this Mac. Do them in order: each starts where the one before left off.

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | ⌘P, open `search.txt`, click **Files** in the editor's column | At the bottom of the column, **Timeline · search.txt**: `Tune the search` (Seed), `Rename to search` (Grace Hopper), `Seed the search page` (Ada Lovelace), newest first, each with its age. Hovering a row shows its full message, author, email, date and id | |
| 2 | Wakil | Click `Rename to search` | A read-only tab `search.txt (<id7>)`: `beta` on the left, `BETA` on the right — the left side read under the old name | |
| 3 | Wakil | Click `Seed the search page` | A tab `old name.txt (<id7>)`: nothing on the left, the three first lines on the right | |
| 4 | Wakil, then Terminal | Right-click `Tune the search` → **Copy Commit ID**, then `pbpaste; echo; git -C "$TMPDIR/walk-3a-v-a/work" rev-parse HEAD~55` | The two lines are the same 40-character id | |
| 5 | Wakil | ⌘P, open `log.txt` | The Timeline lists 50 commits, `Log 55` first, then **Load more**; pressing it adds five more and **Load more** goes | |
| 6 | Wakil | Back on the `search.txt` tab, put the cursor on line 1, then line 2, then line 3 | At the end of the cursor's line, dim: `Ada Lovelace, <age> • Seed the search page`, then `Grace Hopper, … • Rename to search`, then `Seed, … • Tune the search`. Only the cursor's line has one | |
| 7 | Wakil | Put the cursor at the start of line 1, press Return, leave it unsaved, cursor on the new line 1, then line 2; then ⌘S | Unsaved: line 1 reads `Not committed yet`, line 2 Ada Lovelace's, and the Timeline has no **Uncommitted changes** row (the file on disk is unchanged). Saved: the Timeline's top row is **Uncommitted changes**, which opens the file's Changes diff with the new empty line. Then back on `search.txt`, ⌘Z and ⌘S | |
| 8 | Wakil | Cursor on line 2, hover its annotation, click **Open Changes**; hover again, click **Copy Commit ID**; then cursor on line 1, **Open Changes** | The hover shows `Rename to search`, `Grace Hopper · <age> · <id7>`; Open Changes opens the same tab as step 2 (`beta` left, `BETA` right); the id is on the pasteboard (`pbpaste`); line 1's opens the same tab as step 3, `old name.txt (<id7>)` | |
| 9 | Wakil | Settings → Editor → **Inline blame** → Off, back to `search.txt`; then On | Off: no annotation on any line. On: it is back on the cursor's line | |
| 10 | Wakil | In the composer: `who last changed line 2 of search.txt in work, and in which commit?` | The agent answers Grace Hopper, `Rename to search`, without a permission plane | |

## 2. Known and not fixed

- Conflicts, merge and rebase are 3a-v-b's.
- The blame hover shows the commit's subject, not its body; the Timeline row's tooltip and the commit's
  tab carry the rest.
- A rename commit that ends a Timeline page opens without its old name (an empty left side) until the
  next page is loaded.
- The agent may answer step 10 from `git blame` in its shell rather than `editor_blame`; the answer is
  the same (2026-10-24 walk).
- An accessibility "scroll to bottom" (VoiceOver's) on a long lazy list — the Timeline, Search's
  results — traps in SwiftUI and quits Wakil. Search's on main does too; not 3a-v-a's.

## 3. Residue: what the walk cannot establish

- A blame reply landing after its tab lost focus is pinned by `aLateBlameForAnotherTabIsDropped`.
- Names with spaces and non-ASCII letters through history are pinned by `TestFileHistoryFollowsARename`.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is red** — 234 condition(s) of the Cover rung are not met:

```
e2e/checks/unseeded/org-plane.jsonl was run against d696b450ec65 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-1-bundle-path.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-2-block.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-3-live-prompt.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-4-interrupt.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-5-full-screen.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-6-no-orphan.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2c-iii-7-org-switch.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-composer-keeps-input.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-composer-return-sends.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-settings-speech.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-escape.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-lands-focused.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-lands-unsent.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-second-hold.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2d-ii-voice-silence.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-ii-environment-lifecycle.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-ii-git-name-leave-by-tree.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-ii-name-refusals.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-ii-project-lifecycle.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-ii-rename-active-environment.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-iii-api-entries.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-iii-database-edit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-iv-database-edit.jsonl was never run against this build, so nothing is known about it — run `make e2e`
e2e/checks/seeded/2e-settings-databases-dispatch.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-databases.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-doors.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-narrow-rows.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-organisation.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-pane.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-unlink-indicator.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/2e-settings-unlink.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/365-terminal-option-word.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/365-terminal-paste.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/365-terminal-select-backspace.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/365-terminal-select-type.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-b-draft.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-b-message-box-wraps.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-b-ranges.jsonl was run against d696b450ec65 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-commit-all.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-commit.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-discard.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-hook-fails.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-identity.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-message-box.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-settings-tree-collapse.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-stage-change.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-ii-undo.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
.scratch/e2e/dbg/3a-iii-add-project-clone.jsonl was run against 826b4f2c7368 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-git-account-actions.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-git-account-parity.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-git-accounts.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-git-author.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-instructions-boxes.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
.scratch/e2e/defects/3a-iii-remote-button.jsonl was run against 11bc29efe7ae and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-remote-conflict.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-remote-fetch-pull.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-remote-publish-push.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-remote-sync.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iii-settings-maximized.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-branch-blocked.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-branch-menu.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-branch-picker-arrows.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-branch-picker.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-branch-segment-first-git-root.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-stash-by-id.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-stash-menu.jsonl was run against a54e0aba6b7e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-stash-rows.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-iv-switch-branch-palette.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-v-a-inline-blame-setting.jsonl was run against a83c37ca3ae0 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-v-a-timeline-rename.jsonl was run against a83c37ca3ae0 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-v-a-timeline-toggle.jsonl was run against a83c37ca3ae0 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3a-v-a-timeline.jsonl was run against a83c37ca3ae0 and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-close-keys.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-disk-changed.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-files-palette.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-read-only.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-refusals.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-save-as-field.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-save-as-replace.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-scratch-save.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-tabs-language.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-unsaved-org-switch.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-unsaved-quit.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-i-editor-unsaved-save.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-b-replace-all.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-b-replace-cancel.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-b-replace-file.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-b-replace-undo.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-b-reveal.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-b-tab-move.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-find.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-palette-ignored.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-refusals.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-search-cancel.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-search-errors.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-search.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-tree-ignored-heavy.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-tree-live.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-tree-preview.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ii-tree-toggle.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-drill.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-keys.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-list.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-live.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-changes-press.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-diff-open-file.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-diff-refusals.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-git-pane-migrates.jsonl was run against a7e98e02d3de and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-palette-changed-file.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-peek.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iii-tree-letters.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-create-file.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-create-folder.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-name-refused.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-rename-tabs.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-trash-key.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-trash-selection.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-trash-tabs.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-iv-tree-pinned-click.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-ask-agent.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-names-database.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-open-file.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-refused.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-runs.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-switch.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-fast-path-to-agent.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-ix-quick-tasks-about.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-click-focuses-pane.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-autosave-focus.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-autosave-pause.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-autosave-prompt-guard.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-indent-scratch.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-live-options.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-editor-settings-nodes.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-heavy-folders-edit.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-heavy-folders-refusal.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-heavy-folders.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-project-editor-settings.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-v-show-ignored.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-vii-log-follow.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-vii-log-tail.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-ghost-text-setting.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-ghost-unreachable-editor.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-ghost-unreachable-query-line.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-add-focused.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-add.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-dispatch.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-local-provider-remove.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-quick-provider-unlinked.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/3b-viii-quick-provider.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/agent-pane-is-drawn.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-bind.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-body-editor.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-body-hole-cursor.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-bound-locks.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-cancel.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-chip-keys-second-chip.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-chip-keys-text-after.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-chip-keys.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-editor-copy-bound.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-editor-json-holes.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-editor-wrap.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-env-roundtrip.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-hole.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-one-author-focus.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-open.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-paste-curl-hotkey.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-paste-curl-refused.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-paste-curl-www.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-paste-curl.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-query-sync.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-recent-root.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-recent-shared.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-recent.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-reopen-cross-entry.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-rows.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-saved-as-typed.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-send-what-it-shows.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-send.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-set-request.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-surface.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-the-rest.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-type-keeps-holes.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/api-unbind.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/bg-env-switch-own-canvas.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/bg-org-switch-asks-nothing.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/bg-org-switch-keeps-the-terminal.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/capacity-low-reading.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/capacity-passed-reset.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-cancel-click.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-cancel-escape.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-detail-big-cells.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-detail-strip.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-grid-copy.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-query-line-agent-replaces.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-query-line-format.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-query-line-long.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-query-line-not-formatted.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-query-line-return.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/db-query-line-run.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/journal-error-reason.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/landing.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-api-entry.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-api-send.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-command-step.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-escape.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-modes.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-open-kinds.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-run-error.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-switch-environment.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/palette-table-row.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/project-root-note.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/seeded/vocabulary.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-i-code-hint.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-i-failed-source.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-i-hint-or-plain.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-i-over-limit.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-i-pane-hint.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-i-schema-hint.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-ii-thread-earlier.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/2d-ii-voice-turn.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/3a-iii-instructions-reach-agent.jsonl was run against 9dd27b47d6ff and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/3b-iii-changes-voice-hint.jsonl was run against 25427865820b and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/api-origin-after-account-switch.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/bg-agent-chip-more.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/bg-agent-chip-narrow.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/bg-agent-chip-over-landing.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/bg-agent-chip-return.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/both-surfaces.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/capacity-after-turn.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
e2e/checks/agent/two-enter.jsonl was run against ec123ceb418e and this tree is on 8211b7f8c20c — a machine walk recorded from another build certifies another build. Run `make e2e` on this one
the failability record was written against d696b450ec65 and this tree is on 8211b7f8c20c — run `make e2e-new`
coverage could not be computed, so nothing here says whether the surface this branch added carries checks: the action denominator was observed against a83c37ca3ae0 and this tree is on 8211b7f8c20c — measured against the wrong build the gate cannot see an action this branch added, and would pass by being blind. Run `make e2e` to record the current one
```

Walked by `make e2e` against 8211b7f8c20c, rendered 2026-10-23 20:38 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | **another build** (d696b450ec65) | — | — | — |
| `2c-iii-1-bundle-path.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2c-iii-2-block.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2c-iii-3-live-prompt.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2c-iii-4-interrupt.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2c-iii-5-full-screen.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2c-iii-6-no-orphan.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2c-iii-7-org-switch.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-composer-keeps-input.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-composer-return-sends.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-settings-speech.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `2d-ii-voice-escape.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-voice-lands-focused.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-voice-lands-unsent.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-voice-second-hold.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-voice-silence.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2e-ii-environment-lifecycle.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `2e-ii-git-name-leave-by-tree.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `2e-ii-name-refusals.jsonl` | **never run** | — | — | — |
| `2e-ii-project-lifecycle.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `2e-ii-rename-active-environment.jsonl` | **never run** | — | — | — |
| `2e-iii-api-entries.jsonl` | **never run** | — | — | — |
| `2e-iii-database-edit.jsonl` | **never run** | — | — | — |
| `2e-iv-database-edit.jsonl` | **never run** | — | — | — |
| `2e-settings-databases-dispatch.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2e-settings-databases.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2e-settings-doors.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2e-settings-narrow-rows.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2e-settings-organisation.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `2e-settings-pane.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `2e-settings-unlink-indicator.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2e-settings-unlink.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `365-terminal-option-word.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `365-terminal-paste.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `365-terminal-select-backspace.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `365-terminal-select-type.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3a-ii-b-draft.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-ii-b-message-box-wraps.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3a-ii-b-ranges.jsonl` | **another build** (d696b450ec65) | — | — | — |
| `3a-ii-commit-all.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-ii-commit.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-ii-discard.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3a-ii-hook-fails.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-ii-identity.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-ii-message-box.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3a-ii-settings-tree-collapse.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3a-ii-stage-change.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-ii-undo.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iii-add-project-clone.jsonl` | **another build** (826b4f2c7368) | — | — | — |
| `3a-iii-git-account-actions.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-git-account-parity.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-git-accounts.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-git-author.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-instructions-boxes.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-remote-button.jsonl` | **another build** (11bc29efe7ae) | — | — | — |
| `3a-iii-remote-conflict.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-remote-fetch-pull.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iii-remote-publish-push.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-remote-sync.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iii-settings-maximized.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3a-iv-branch-blocked.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-branch-menu.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-branch-picker-arrows.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-branch-picker.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-branch-segment-first-git-root.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-stash-by-id.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-stash-menu.jsonl` | **another build** (a54e0aba6b7e) | — | — | — |
| `3a-iv-stash-rows.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-iv-switch-branch-palette.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3a-v-a-inline-blame-setting.jsonl` | **another build** (a83c37ca3ae0) | — | — | — |
| `3a-v-a-timeline-rename.jsonl` | **another build** (a83c37ca3ae0) | — | — | — |
| `3a-v-a-timeline-toggle.jsonl` | **another build** (a83c37ca3ae0) | — | — | — |
| `3a-v-a-timeline.jsonl` | **another build** (a83c37ca3ae0) | — | — | — |
| `3b-i-editor-close-keys.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-disk-changed.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-files-palette.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-read-only.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-refusals.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-i-editor-save-as-field.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-i-editor-save-as-replace.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-scratch-save.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-tabs-language.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-unsaved-quit.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-i-editor-unsaved-save.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-b-replace-all.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-b-replace-cancel.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-b-replace-file.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-b-replace-undo.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-b-reveal.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ii-b-tab-move.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-find.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-palette-ignored.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-refusals.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ii-search-cancel.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-search-errors.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-search.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-tree-ignored-heavy.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-tree-live.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-tree-preview.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-ii-tree-toggle.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iii-changes-drill.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3b-iii-changes-keys.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-iii-changes-list.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iii-changes-live.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3b-iii-changes-press.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3b-iii-diff-open-file.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3b-iii-diff-refusals.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3b-iii-git-pane-migrates.jsonl` | **another build** (a7e98e02d3de) | — | — | — |
| `3b-iii-palette-changed-file.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-iii-peek.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-iii-tree-letters.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-iv-create-file.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-create-folder.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-name-refused.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-rename-tabs.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-trash-key.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-trash-selection.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-trash-tabs.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iv-tree-pinned-click.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-ask-agent.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-names-database.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-open-file.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-refused.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-runs.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-switch.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-fast-path-to-agent.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-ix-quick-tasks-about.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-click-focuses-pane.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-editor-autosave-focus.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-editor-autosave-pause.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-editor-indent-scratch.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-editor-live-options.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-editor-settings-nodes.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-v-heavy-folders-edit.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-v-heavy-folders-refusal.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-v-heavy-folders.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-v-project-editor-settings.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-v-show-ignored.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-vii-log-follow.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-vii-log-tail.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-viii-ghost-text-setting.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-viii-ghost-unreachable-editor.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-viii-ghost-unreachable-query-line.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-viii-local-provider-add-focused.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-viii-local-provider-add.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3b-viii-local-provider-dispatch.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-viii-local-provider-remove.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-viii-quick-provider-unlinked.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-viii-quick-provider.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `agent-pane-is-drawn.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-bind.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-body-editor.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-body-hole-cursor.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-bound-locks.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-cancel.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-chip-keys-second-chip.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-chip-keys-text-after.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-chip-keys.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-editor-copy-bound.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-editor-json-holes.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-editor-wrap.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-env-roundtrip.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-hole.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-one-author-focus.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-open.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-paste-curl-hotkey.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-paste-curl-refused.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-paste-curl-www.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-paste-curl.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-query-sync.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-recent-root.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-recent-shared.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-recent.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-reopen-cross-entry.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-rows.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-saved-as-typed.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-send-what-it-shows.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-send.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-set-request.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-surface.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-the-rest.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-type-keeps-holes.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `api-unbind.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-env-switch-own-canvas.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-org-switch-asks-nothing.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-org-switch-keeps-the-terminal.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `capacity-low-reading.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `capacity-passed-reset.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `db-cancel-click.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-cancel-escape.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-detail-big-cells.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-detail-strip.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-grid-copy.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-query-line-agent-replaces.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-query-line-format.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-query-line-long.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-query-line-not-formatted.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-query-line-return.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `db-query-line-run.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `journal-error-reason.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `landing.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-api-entry.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-api-send.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-command-step.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-escape.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-modes.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-open-kinds.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-run-error.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-switch-environment.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `palette-table-row.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `project-root-note.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `vocabulary.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-i-code-hint.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-i-failed-source.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-i-hint-or-plain.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-i-over-limit.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-i-pane-hint.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-i-schema-hint.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-thread-earlier.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `2d-ii-voice-turn.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `3a-iii-instructions-reach-agent.jsonl` | **another build** (9dd27b47d6ff) | — | — | — |
| `3b-iii-changes-voice-hint.jsonl` | **another build** (25427865820b) | — | — | — |
| `api-origin-after-account-switch.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-agent-chip-more.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-agent-chip-narrow.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-agent-chip-over-landing.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `bg-agent-chip-return.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `both-surfaces.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `capacity-after-turn.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `two-enter.jsonl` | **another build** (ec123ceb418e) | — | — | — |
| `.scratch/e2e/dbg/3a-iii-add-project-clone.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/dbg/probe-org.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/defects/3a-iii-git-reads-schema.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/defects/3a-iii-remote-button.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/defects/3a-iii-sheet-first-field.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/defects/clone/3a-iii-add-project-clone.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/findings/seeded/finding-agent-delete-plane.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/findings/seeded/finding-picker-arrows.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/findings/seeded/finding-segment-first-git-root.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `.scratch/e2e/tmpchecks/focus-probe.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3a-v-a-timeline-more.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` saw every check this branch added go red against c31d96c4ac7b.**

**Coverage is unknown**, so nothing here says whether the surface this branch added carries checks. Run `make e2e`, which ends in the gate.

```
the action denominator was observed against a83c37ca3ae0 and this tree is on 8211b7f8c20c — measured against the wrong build the gate cannot see an action this branch added, and would pass by being blind. Run `make e2e` to record the current one
```


<!-- /machine-walk -->
