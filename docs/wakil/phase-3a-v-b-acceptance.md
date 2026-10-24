# 3a-v-b — conflicts: acceptance

**Spec:** [`2026-10-23-3a-v-conflicts-history-blame-design.md`](../superpowers/specs/2026-10-23-3a-v-conflicts-history-blame-design.md)
· **Plan:** [`2026-10-24-3a-v-b-conflicts.md`](../superpowers/plans/2026-10-24-3a-v-b-conflicts.md)
· **Charter:** Invariant 6 (the ninth write), Decision 47, Decisions 44 and 46 amended

The exit criterion, from the spec: the operator merges and rebases from the Changes view, and a
merge, rebase, pull or stash that clashes stops with the conflicts left in place, as VS Code leaves
them; each block is resolved in the editor with Accept Current, Incoming or Both, or a whole file
from its row, then committed or continued; Abort, Skip, the whole-file takes and Undo Apply ask in
place first; the agent reaches the same actions, and those four raise the permission plane.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the worktree root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run.

```bash
(
set -e
REPO="$(git rev-parse --show-toplevel)"
ORG=personal
W="$TMPDIR/walk-3a-v-b"
rm -rf "$W"
mkdir -p "$W/project"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
as() { n="$1"; shift; git -c user.name="$n" -c user.email="$(echo "$n" | tr 'A-Z ' 'a-z.')@example.com" "$@"; }
lines() { printf '%s\n' "$1" two three four five six seven eight nine "$2"; }
git init -q -b main "$W/work"
cd "$W/work"
{ seq 1 60; lines alpha omega; } > search.txt
echo home > index.txt
lines notes end > notes.txt
printf 'one\ntwo\n' > todo.txt
printf '<<<<<<< a\nnot\n=======\na conflict\n>>>>>>> b\n' > sample.txt
git add . && as "Ada Lovelace" commit -qm "Seed the search page"
as "Grace Hopper" switch -qc feature/search
{ seq 1 60; lines "alpha (search)" "omega (search)"; } > search.txt && echo "home (search)" > index.txt
as "Grace Hopper" commit -qam "Search the index"
git switch -q main && git switch -qc rework
lines "notes (rework)" end > notes.txt && as "Grace Hopper" commit -qam "Rework the notes"
echo readme > readme.txt && git add readme.txt && as "Grace Hopper" commit -qm "Add a readme"
lines "notes (rework)" "end (rework)" > notes.txt && as "Grace Hopper" commit -qam "Close the notes"
git switch -q main
printf 'one\nMINE\n' > todo.txt && as "Ada Lovelace" stash push -q -m "tune the todo list"
{ seq 1 60; lines "alpha (main)" "omega (main)"; } > search.txt && echo "home (main)" > index.txt
lines "notes (main)" "end (main)" > notes.txt && printf 'one\nTWO\n' > todo.txt
as "Ada Lovelace" commit -qam "Tune main"
git init -q --bare -b main "$W/remote.git"
git clone -q "$W/remote.git" "$W/elsewhere" 2>/dev/null
cd "$W/elsewhere"
echo shared > pull.txt && echo old > gone.txt
git add . && as "Ada Lovelace" commit -qm "Seed the team files" && git push -q -u origin main
git clone -q "$W/remote.git" "$W/team"
echo "shared (theirs)" > pull.txt && git rm -q gone.txt
as "Grace Hopper" commit -qam "Drop gone.txt" && git push -q
cd "$W/team"
echo "shared (mine)" > pull.txt && echo "old (mine)" > gone.txt
as "Ada Lovelace" commit -qam "Tune the team files"
cat > "$W/project/project.json" <<J
{"name":"walk-3a-v-b","org":"$ORG","roots":[{"path":"$W/work"},{"path":"$W/team"}],"scopes":{},"environments":{}}
J
cd "$REPO"
./bin/wakil project rm walk-3a-v-b --org "$ORG" || true
./bin/wakil project add walk-3a-v-b --path "$W/project/project.json" --org "$ORG"
)
```

`work` is on `main` with no remote: `feature/search` (Grace Hopper) and `main` (Ada Lovelace)
changed lines 61 and 70 of `search.txt` and the one line of `index.txt` differently;
`rework` has three commits — `Rework the notes` and `Close the notes` clash with `main`'s
`notes.txt`, `Add a readme` does not; the stash `tune the todo list` clashes with `main`'s
`todo.txt`; `sample.txt` holds a marker block git did not write. `team` is a clone one commit
ahead, whose remote has a teammate's commit it has not fetched: `pull.txt` changed and `gone.txt`
deleted. Set Settings → Organisation → Git → Pull strategy to **Rebase** if an earlier walk changed
it. Launch from the worktree root with
`WAKIL_ORG=personal WAKIL_GIT_ALLOW_FILE=1 app/Wakil.app/Contents/MacOS/Wakil`, make `walk-3a-v-b`
active with ⌘P, open an editor pane and press ⌘⇧G. Terminal commands run from any folder.

## 1. The walk

Each row is one thing to do. **Wakil** rows happen in the app; **Terminal** rows run in any folder on
this Mac. Do them in order: each starts where the one before left off.

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | On `work`'s header, **⋯** → Branch → **Merge Branch…**, press Escape; open it again and pick `feature/search` | The picker opens with its filter focused, listing `feature/search` and `rework` but not `main`; Escape closes it. After the pick, under the box in amber: `Merge stopped on conflicts in index.txt, search.txt; resolve them below`. Under the header, amber: `merging feature/search`. A **Merge Changes 2** group sits above the others: `index.txt  both modified`, `search.txt  both modified`. The button reads **Commit Merge**, disabled, with `Resolve 2 conflicts first` | |
| 2 | Wakil | **▾** → **Abort Merge**, press **Keep it**; **▾** → **Abort Merge** again, press **Abort**. Then merge `feature/search` again as in row 1 | Under the commit bar: `Abort the merge? The tree goes back to before it, and your resolutions are lost.` with **Keep it** and **Abort**. Keep it changes nothing. Abort: Merge Changes and the amber line go and the header reads `work · main · clean`. The second merge stops as row 1 did | |
| 3 | Wakil | ⌘P, open `sample.txt`; ⌘P, open `search.txt`; ⌘K → **Next Conflict**, then ⌘K → **Previous Conflict**; on the first block press **Compare Changes** | `sample.txt` shows no tint and no actions row. `search.txt` opens scrolled to its first block, at line 61. Both blocks are tinted, each with `Accept Current Change · Accept Incoming Change · Accept Both Changes · Compare Changes` above it, and the marker lines end in a dim `(Current Change)` / `(Incoming Change)`. Next Conflict moves the cursor to line 74, Previous back to line 61. Compare opens a read-only tab `search.txt (Current ↔ Incoming)`: `alpha (main)` and `omega (main)` on the left, `(search)` on the right | |
| 4 | Wakil | Back on `search.txt`: first block **Accept Current Change**, ⌘S, then **+** on the `search.txt` row and right-click that row under Staged. Back in the tab: second block **Accept Incoming Change**, ⌘Z, **Accept Incoming Change** again, ⌘S, and **+** on `search.txt` again | The first block reads `alpha (main)` and the cursor stays there. After the first **+** the row is under Staged as `search.txt — staged with conflict markers`, in amber; right-clicking it opens no menu; the tab still shows the second block's actions row; the reason reads `Resolve 1 conflict first`. ⌘Z brings the second block back whole with the cursor in place. After the second **+**, `search.txt` is under Staged with no amber, ending `omega (search)` | |
| 5 | Wakil, then Terminal | Right-click `index.txt` → **Accept All Incoming**, press **Keep it**; again → **Accept**. Then press **Commit Merge**. Then `git -C "$TMPDIR/walk-3a-v-b/work" log -1 --format='%s / %p'` | In place: `Take all of feature/search's index.txt? Any edits you made to it are lost.` with **Keep it** and **Accept**; Keep it changes nothing. After Accept, `index.txt` is under Staged, the reason goes and the box holds `Merge branch 'feature/search'`. After Commit Merge the amber line and Merge Changes go. Terminal prints `Merge branch 'feature/search' / ` and two short ids | |
| 6 | Wakil | Click `work`'s branch name in its header, pick `rework`. **⋯** → Branch → **Rebase Branch…**, pick `main`. ⌘P, open `notes.txt`, press **Accept Both Changes**, ⌘S, **+** on `notes.txt`, then **Continue Rebase** | The rebase stops: `Rebase stopped on conflicts in notes.txt (step 1 of 3); resolve them below`, amber `rebasing 1/3 onto main`, **Continue Rebase** disabled with `Resolve 1 conflict first`, and ▾ holds **Skip Commit** and **Abort Rebase**. Accept Both leaves `notes (main)` then `notes (rework)`. Continue applies step 2 and stops on the third: `rebasing 3/3 onto main`, `Rebase stopped on conflicts in notes.txt (step 3 of 3); resolve them below` | |
| 7 | Wakil, then Terminal | **▾** → **Skip Commit**, press **Keep it**; again → **Skip**. Then `git -C "$TMPDIR/walk-3a-v-b/work" log --format=%s main..rework` | In place: `Skip <id7> "Close the notes"? Its changes are left out of the rebase.` with **Keep it** and **Skip**. After Skip the amber line goes and the header reads `work · rework · clean`. Terminal prints `Add a readme`, then `Rework the notes` | |
| 8 | Wakil | Pick `main` from `work`'s branch name; `work` is clean, so `todo.txt` holds no change of yours and the apply offers Undo Apply. Open **Stashes**, hover `tune the todo list` → **Apply**. Then **Undo Apply** on the Merge Changes header, **Keep it**; **Undo Apply** again, **Undo** | After Apply: `Your stash clashes with main in todo.txt; resolve it below, or Undo Apply`; Merge Changes holds `todo.txt  both modified` with **Undo Apply** on its header; no amber state line; **Commit All** is disabled with `Resolve 1 conflict first`. Undo Apply asks `Undo applying "tune the todo list"? The files it touched go back to HEAD; the stash stays in the list.` After **Undo** the header reads `work · main · clean` and Stashes still lists `tune the todo list` | |
| 9 | Wakil | On `team`'s header: **⋯** → **Fetch**, then press **Sync** | After Fetch the header reads `team · main ↑1 ↓1 · clean`. After Sync, under `team`'s box in amber: `Pull stopped on conflicts in gone.txt, pull.txt; resolve them below`; amber `rebasing 1/1 onto origin/main`; Merge Changes holds `gone.txt  deleted by us` and `pull.txt  both modified`, and nothing was pushed | |
| 10 | Wakil, then Terminal | In the composer: `In team, keep the file gone.txt.` Then: `In team, take the incoming side of pull.txt.`, and approve the plane. Press **Continue Rebase**. Then `cat "$TMPDIR/walk-3a-v-b/team/pull.txt" "$TMPDIR/walk-3a-v-b/team/gone.txt"` | The first is done without a permission plane (`editor_changes_keep_file`) and `gone.txt` leaves Merge Changes. The second raises the plane: `take the incoming pull.txt whole in team; edits made to it are lost`; after approval `pull.txt` leaves it too. Continue finishes: the header reads `team · main ↑1 · clean`. Terminal prints `shared (mine)`, then `old (mine)` | |

## 2. Known and not fixed

- The picker shows no spinner and Escape cannot cancel while a merge or rebase it started runs
  (Rules 4/5), as Switch's.
- **Amend Last Commit** stays enabled in ▾ while conflicts remain.
- The Compare tab is not refreshed when the conflict changes; close and reopen it.
- An Accept moves the cursor to its block even when the cursor was elsewhere in the file.
- After a relaunch, or for a clash made in a terminal, there is no Undo Apply: resolve it by hand.
- Undo Apply is offered only when the stash's files had no changes of your own before the apply;
  otherwise the clash is left to resolve by hand, as VS Code leaves it.
- The agent may resolve row 10 with git in its shell instead of the editor tools; the files end the
  same.
- VS Code's three-way Merge Editor, the Source Control Graph, starting a cherry-pick or revert,
  interactive rebase and `merge --squash` are not in this phase.

## 3. Residue: what the walk cannot establish

- Undo Apply refused once a clashed file changed (`todo.txt changed since the clash; Undo Apply
  would lose that — resolve it by hand`) and once the stash is gone (`The stash is gone, so Undo
  Apply would lose its changes; resolve it by hand`) are pinned by `TestUndoApplyRefusesAnEditedFile`
  and `TestUndoApplyRefusesWhenTheStashIsGone`.
- Continue Rebase with no editor configured is pinned by `TestContinueRebaseNeedsNoEditor`.
- Blocks at the first and last line, CRLF endings and a lone `=======` are pinned by
  `aBlockAtTheFirstAndLastLine`, `crlfIsKept` and `aLoneSeparatorIsNotABlock`.
- A clash record with spaces and non-ASCII names is pinned by
  `TestUndoApplyNeverDeletesTheOperatorsFiles`.
- A pull cancelled part-way still undoing its rebase is pinned by `TestACancelledPullUndoesItsRebase`.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
