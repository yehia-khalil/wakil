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
| 7 | Wakil | Put the cursor at the start of line 1, press Return, leave it unsaved, cursor on the new line 1, then line 2 | Line 1 reads `Not committed yet`; line 2 reads Ada Lovelace's. The Timeline's top row is now **Uncommitted changes**, which opens the file's Changes diff. Then ⌘Z | |
| 8 | Wakil | Cursor on line 2, hover its annotation, click **Open Changes**; hover again, click **Copy Commit ID** | The hover shows `Rename to search`, `Grace Hopper · <age> · <id7>`; Open Changes opens the same tab as step 2; the id is on the pasteboard (`pbpaste`) | |
| 9 | Wakil | Settings → Editor → **Inline blame** → Off, back to `search.txt`; then On | Off: no annotation on any line. On: it is back on the cursor's line | |
| 10 | Wakil | In the composer: `who last changed line 2 of search.txt in work, and in which commit?` | The agent answers Grace Hopper, `Rename to search`, from `editor_blame`, without a permission plane | |

## 2. Known and not fixed

- Conflicts, merge and rebase are 3a-v-b's.
- The blame hover shows the commit's subject, not its body; the Timeline row's tooltip and the commit's
  tab carry the rest.
- A rename commit that ends a Timeline page opens without its old name (an empty left side) until the
  next page is loaded.
- Blame's Open Changes opens the commit under the file's current name; for a commit before a rename,
  open it from the Timeline.

## 3. Residue: what the walk cannot establish

- A blame reply landing after its tab lost focus is pinned by `aLateBlameForAnotherTabIsDropped`.
- Names with spaces and non-ASCII letters through history are pinned by `TestFileHistoryFollowsARename`.
