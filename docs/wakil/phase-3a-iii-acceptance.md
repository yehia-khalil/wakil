# 3a-iii — git accounts, remotes and agent instructions: acceptance

**Spec:** [`2026-10-22-3a-iii-git-accounts-and-remotes-design.md`](../superpowers/specs/2026-10-22-3a-iii-git-accounts-and-remotes-design.md)
· **Charter:** Invariant 6 (the seventh write), Decisions 44 and 45

The exit criterion, from the spec: from the Changes view the operator fetches, pulls, pushes, syncs
and publishes each root with the organisation's own account, without a dialog; voice and the
composer push too. A conflicting pull leaves the tree as it was. Settings → Organisation → Git
holds the accounts and the pull strategy; + Add a project clones from a link; the agent follows the
organisation's and the project's instructions from its next turn.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the worktree root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run. Rows 1–7 use a bare repository on this Mac as the remote, which is why Wakil is launched
with `WAKIL_GIT_ALLOW_FILE=1`; rows 8 and 9 use your GitHub account.

```bash
(
set -e
ORG=personal
W="$TMPDIR/walk-3a-iii"
rm -rf "$W"
mkdir -p "$W/project" "$W/clones"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=seed -c user.email=seed@example.com "$@"; }
git init -q --bare -b main "$W/remote.git"
git clone -q "$W/remote.git" "$W/work"
cd "$W/work"
printf 'one\ntwo\nthree\n' > a.txt
git add . && g commit -qm seed && git push -q -u origin main
git clone -q "$W/remote.git" "$W/elsewhere"
cd "$W/work"
echo ahead > ahead.txt && git add . && g commit -qm 'walk: ahead'
cat > "$W/project/project.json" <<J
{"name":"walk-3a-iii","org":"$ORG","roots":[{"path":"$W/work"}],"scopes":{},"environments":{}}
J
cd /Users/yehia/orca/workspaces/wakil-public/sealion
./bin/wakil project rm walk-3a-iii --org "$ORG" || true
./bin/wakil project add walk-3a-iii --path "$W/project/project.json" --org "$ORG"
)
```

`work` is the root Wakil shows, one commit ahead of the remote. `elsewhere` is a second clone you
push from in Terminal, to play a teammate. Set Settings → Organisation → Git → Pull strategy to
**Rebase** before row 1 if an earlier walk changed it.

Launch with
`cd /Users/yehia/orca/workspaces/wakil-public/sealion && WAKIL_ORG=personal WAKIL_GIT_ALLOW_FILE=1 app/Wakil.app/Contents/MacOS/Wakil`,
make `walk-3a-iii` active with ⌘P, open an editor pane and press ⌘⇧G. Keep a Terminal window open;
every Terminal command below is run from any folder.

## 1. The walk

Walk in order, on `walk-3a-iii`, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | **Push.** In the Changes view, press the remote button on `work`'s header. Then in Terminal: `git -C "$TMPDIR/walk-3a-iii/remote.git" log -1 --format=%s` | The button reads **Push** (↑1) before the press, then goes. No dialog. Terminal prints `walk: ahead` | |
| 2 | **Fetch, then Pull over your own work.** Terminal: `cd "$TMPDIR/walk-3a-iii/elsewhere" && git pull -q && echo theirs > b.txt && git add b.txt && git -c user.name=mate -c user.email=mate@example.com commit -qm 'walk: theirs' && git push -q && echo wip > "$TMPDIR/walk-3a-iii/work/wip.txt"`. In Wakil: ▾ → **Fetch**, then press **Pull** | After Fetch the button reads **Pull** (↓1). After Pull, `b.txt` is in the Files tree, `wip.txt` is still under Untracked, and the button goes | |
| 3 | **A conflicting Sync.** Terminal: `cd "$TMPDIR/walk-3a-iii/elsewhere" && printf 'one\nTHEIRS\nthree\n' > a.txt && git commit -qam 'walk: theirs a' && git push -q && cd ../work && printf 'one\nMINE\nthree\n' > a.txt && git -c user.name=me -c user.email=me@example.com commit -qam 'walk: mine a'`. In Wakil: ▾ → **Fetch**, then press **Sync**. Then Terminal: `git -C "$TMPDIR/walk-3a-iii/work" status --short; ls "$TMPDIR/walk-3a-iii/work/.git" \| grep -c rebase` | Under the box, in amber: `Pull stopped on conflicts in a.txt; nothing was changed. Resolve them in a terminal, or wait for the conflict view (3a-v)`. Terminal prints nothing from `status`, then `0` | |
| 4 | **Your own merge is left alone.** Terminal: `git -C "$TMPDIR/walk-3a-iii/work" merge --no-edit @{u}` (it conflicts). In Wakil press **Sync** again. Then Terminal: `ls "$TMPDIR/walk-3a-iii/work/.git/MERGE_HEAD" && git -C "$TMPDIR/walk-3a-iii/work" merge --abort` | Under the box: `A merge is in progress in …/work; finish or abort it first`. `ls` finds `MERGE_HEAD` (your merge was not aborted by Wakil) | |
| 5 | **Pull strategy.** Terminal: `cd "$TMPDIR/walk-3a-iii/work" && git reset -q --hard @{u} && echo c > c.txt && git add c.txt && git -c user.name=me -c user.email=me@example.com commit -qm 'walk: mine c' && cd ../elsewhere && git pull -q && echo d > d.txt && git add d.txt && git -c user.name=mate -c user.email=mate@example.com commit -qm 'walk: theirs d' && git push -q`. ⌘, → Organisation → **Git** → Pull strategy **Fast-forward only**; close Settings, ▾ → **Fetch**, press **Sync**. Then set **Merge** and press **Sync** again. Terminal: `git -C "$TMPDIR/walk-3a-iii/work" log -1 --format=%s` | With Fast-forward only, under the box: `Both sides have new commits, so Fast-forward only cannot pull. Choose Rebase or Merge in Settings → Organisation → Git`, and nothing changes. With Merge it goes through: Terminal prints a `Merge branch 'main' …` subject, and the button goes. Set it back to **Rebase** | |
| 6 | **Publish.** Terminal: `cd "$TMPDIR/walk-3a-iii/work" && git switch -qc walk-publish && echo p > p.txt && git add p.txt && git -c user.name=me -c user.email=me@example.com commit -qm 'walk: publish'`. In Wakil press the button. Terminal: `git -C "$TMPDIR/walk-3a-iii/remote.git" branch` | The button reads **Publish** before the press. Terminal lists `walk-publish` | |
| 7 | **Voice pushes.** Terminal: `cd "$TMPDIR/walk-3a-iii/work" && echo v > v.txt && git add v.txt && git -c user.name=me -c user.email=me@example.com commit -qm 'walk: voice'`. Hold ⌥ and say "push work", release, Return. Terminal: `git -C "$TMPDIR/walk-3a-iii/remote.git" log -1 --format=%s walk-publish` | An agent turn calls `editor_changes_push`; no confirmation is asked. Terminal prints `walk: voice` | |
| 8 | **An SSH account Wakil generates.** ⌘, → Organisation → **Git** → Accounts → add → Provider **GitHub** → **SSH key** → **Generate a new key** → **Copy** → **Open github.com's SSH keys page**, add the key there. Back in the sheet press **Test connection** | `✓ github.com knows this account as <your GitHub user>`. The account row shows the key's name. No file under `~/.ssh` changed: `ls -t ~/.ssh \| head -3` shows nothing new | |
| 9 | **Clone from a link.** ⌘, → Projects → **+ Add a project** → **Clone from a link…** → `git@github.com:yehia-khalil/wakil.git`, Terminal: `echo "$TMPDIR/walk-3a-iii/clones" \| pbcopy`; **Choose where to clone** → ⇧⌘G in the panel, ⌘V, Return → **Clone** | **Cloning…** then the project `wakil` is in the tree; ⌘⇧G shows its root clean. Remove it afterwards from its Settings page | |
| 10 | **Agent instructions.** ⌘, → Organisation → **Agent** → General: `End every reply with the word WALK.`, then click the Display name field. Open the `walk-3a-iii` project page → **Agent** → Commits: `Start every commit subject with WALK:`, click elsewhere. Close Settings. In the composer: `hello`. Then Terminal: `echo e >> "$TMPDIR/walk-3a-iii/work/a.txt"`, and in the Changes view press ✨ in `work`'s message box | Both boxes keep their text with no Save press (reopen Settings: they are there). The agent was live since row 7, so the thread shows `Instructions updated — the agent has the new ones from this turn.` and the reply ends with `WALK`. ✨'s draft subject starts with `WALK:`. Clear both boxes afterwards | |

## 2. Known and not fixed

- **Sign in (device flow) is hidden** for GitHub and GitLab.com until Wakil's OAuth apps are
  registered and their client ids set (`operator-todo.md`). **Use a gh login** works now.
- **Deferred from the whole-branch review** (each is a `minor (deferred)` line in the 3a-iii-b
  ledger): hosts are not validated as `hostname[:port]`; conflict paths with spaces are listed split;
  an instructions update is lost if that turn's send fails; the account Test has no Cancel; a clone
  whose sheet is closed still adds its project; credentials pasted into a clone link bypass Wakil's
  helper and are journalled; the device code is journalled; a ProxyJump hop does not get the
  organisation's key; Wakil's own `known_hosts` does not inherit `~/.ssh/known_hosts`.
- **The agent's own shell** pushes with whatever the Mac's git and ssh are set up for, not the
  organisation's account; only the `editor_changes_*` actions carry it.

## 3. Residue: what the walk cannot establish

- **Sign in with GitHub / GitLab** cannot be walked until the client ids exist.
- **A token account** on Bitbucket or a self-hosted host needs such an account; the helper's
  host check and the alias rewrite are pinned by `cmd/wakil` and `internal/wakilcore` tests.
- **An org switch during a long push** (cancelled cleanly after 60 s) and **a background fetch to a
  host that never answers** (given up after a minute, pre-empted by your own write) are pinned by
  tests; the walk's remote answers at once.
- **Background fetch every five minutes** is not waited for here; row 2's ▾ → Fetch is the same
  action.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
