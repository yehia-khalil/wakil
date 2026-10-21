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
<!-- /machine-walk -->
