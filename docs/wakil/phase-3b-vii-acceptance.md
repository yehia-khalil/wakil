# 3b-vii — large files and logs: acceptance

**Spec:** [`2026-10-18-3b-vii-large-files-and-logs-design.md`](../superpowers/specs/2026-10-18-3b-vii-large-files-and-logs-design.md)

The exit criterion, from the spec: a growing Laravel log is followed in the editor — over 2 MB it
opens as its last 2 MB under a strip saying so, new lines are appended and followed while the view
is at the bottom, entries are coloured and fold, and project search names the files over 2 MB it
skipped.

## 0. Setup

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run.

```bash
(
set -e
ORG=personal
cd ~/Desktop/scripts/wakil-public-3b-vii
W="$TMPDIR/walk-logs"
rm -rf "$W"
mkdir -p "$W/app/storage/logs" "$W/project"
L="$W/app/storage/logs"
entry() { # level message
  printf '[%s] local.%s: %s {"exception":"[object] (Exception(code: 0): %s at /var/www/app/Http/Kernel.php:42)\n[stacktrace]\n#0 /var/www/vendor/laravel/framework/src/Illuminate/Pipeline/Pipeline.php(183): handle()\n#1 /var/www/vendor/laravel/framework/src/Illuminate/Routing/Router.php(799): then()\n#2 {main}\n"}\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$2"
}
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf '[%s] local.INFO: request %s served\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$i" >> "$L/laravel.log"
  [ $((i % 4)) = 0 ] && entry ERROR "SQLSTATE[23000]: Integrity constraint violation $i" >> "$L/laravel.log"
  [ $((i % 5)) = 0 ] && printf '[%s] local.WARNING: slow query %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$i" >> "$L/laravel.log"
done
yes '[2026-10-18 09:00:00] local.DEBUG: filler line for a large log' | head -c 3000000 > "$L/big.log"
entry ERROR "the last error in the big log" >> "$L/big.log"
echo '# app' > "$W/app/README.md"
cat > "$W/append.sh" <<'A'
#!/bin/bash
L="$TMPDIR/walk-logs/app/storage/logs/${1:-laravel.log}"
printf '[%s] local.ERROR: appended at %s {"exception":"[object] (Exception(code: 0): boom)\n[stacktrace]\n#0 /var/www/app/Http/Kernel.php(42): handle()\n#1 {main}\n"}\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date '+%H:%M:%S')" >> "$L"
echo "appended to $L"
A
cat > "$W/project/project.json" <<J
{"name":"walk-logs","org":"$ORG","roots":[{"path":"$W/app"}],"scopes":{},"environments":{}}
J
./bin/wakil project rm walk-logs --org "$ORG" || true
./bin/wakil project add walk-logs --path "$W/project/project.json" --org "$ORG"
)
```

Launch with
`cd ~/Desktop/scripts/wakil-public-3b-vii && WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`,
make `walk-logs` active with ⌘P, and open an editor pane. Appends are run in Terminal.app (not in
Wakil, so the editor stays in front): `bash "$TMPDIR/walk-logs/append.sh"`, or with `big.log` after
it for the large log.

## 1. The walk

Walk in order, on `walk-logs`, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | ⌘P `laravel.log`, open it | It opens at the bottom. Each entry is one line: the ERRORs folded to their first line with a fold arrow, the INFO and WARNING lines alone | |
| 2 | Look at the colours | Timestamps dim; `ERROR` red, `WARNING` amber, `INFO` plain; nothing else coloured | |
| 3 | Click an ERROR's fold arrow | Its trace opens beneath it; the `[stacktrace]` and `#0 …` lines are dimmed | |
| 4 | In Terminal: `bash "$TMPDIR/walk-logs/append.sh"` | The new ERROR appears at the bottom, folded, and the view moves to show it. The trace you opened in row 3 stays open | |
| 5 | Scroll to the top, run the append again | The view stays at the top. Scroll back to the bottom: the new entry is there; one more append is followed again | |
| 6 | Run `: > "$TMPDIR/walk-logs/app/storage/logs/laravel.log"`, then the append | The tab empties, then shows only the newly appended entry | |
| 7 | ⌘P `big.log`, open it | A strip reads `Showing the last 2 MB of 3 MB`; the view is at the bottom on `the last error in the big log`; typing changes nothing | |
| 8 | In Terminal: `bash "$TMPDIR/walk-logs/append.sh" big.log` | The new entry appears at the bottom of `big.log`'s tab, folded, followed; the strip still reads 3 MB | |
| 9 | ⌘⇧F, search `ERROR` | Matches from `laravel.log`; under the results, `1 file over 2 MB not searched: storage/logs/big.log` | |
| 10 | Open `README.md`, change it in Terminal (`echo hi >> "$TMPDIR/walk-logs/app/README.md"`) | It reloads whole as before, keeping where you were — only logs append | |

## 2. Residue — what the walk cannot establish

- **More than 2 MB written between two reads** (the tab rereads a fresh tail) and **a binary chunk**
  (the tab stops following and says so): both need writes faster or stranger than a walk makes;
  unit tests pin them (`EditorLogTests`).
- **A log emptied and rewritten past its old length before the editor re-reads it** shows a wrong
  splice until the next shrink or reopen — the plan's accepted cost.

## 3. Cover — what the e2e auditor covered and could not

Two checks, each proved red and then green:

- `3b-vii-log-tail.jsonl` — a 3 MB log opens as its tail: language `log`, the strip's text in the
  pane and on screen, the newest entry in view, Save refused naming the strip; an appended line is
  in view after the editor is brought forward; search over it lists `big.log` in `skipped_large`
  and shows `1 file over 2 MB not searched: big.log`.
- `3b-vii-log-follow.jsonl` — a 200-line `small.log` opens with its cursor on the last line and
  line 200 in view; an appended WARNING is in view, the tab clean and in sync.

**Proved red against `1d1a6f2`, not the merge-base.** The merge-base `a639cf6` (main) does not
compile — two 3b-iv calls predate the background-agents rename (fixed on this branch in `86d9e59`) —
so `make e2e-new` could not build it. `1d1a6f2` is main plus that fix alone, so each check's red is
3b-vii's absence, and the reasons were read: `plaintext` for `log`, the old `files over 2 MB open in
3b-v` notice, cursor on line 1, the appended line out of view.

**The editor checks, run by hand** (the selector maps the renderer and the page to no check): 55 of
the 61 `e2e/checks/seeded/3b-*.jsonl` ran green on this branch, both new ones among them. The six
that did not are red on main the same way and are not this branch's: `3b-iv-create-file`,
`3b-iv-create-folder`, `3b-iv-name-refused`, `3b-iv-trash-key` and `3b-iv-tree-pinned-click`
dispatch `ctx_set_project`, which the background-agents stack now refuses ("this process's place is
pinned"); `3b-v-click-focuses-pane` is #16.

`editor.search.largeNote` is display text with no press action; `e2e/checks/uncoverable.tsv` names
the check that reads it.

The residue — what no check covers, and why:

- **Colours, folding, and which entries start folded** (rows 1–3) — walk-only: Monaco's tokens and
  folds are not in the accessibility tree or `read_pane`.
- **Following stops when scrolled up** (row 5) — walk-only: a check cannot scroll Monaco by a set
  amount; the store's rule is pinned by `anAppendWhileScrolledUpLeavesTheCursor`.
- **An opened trace stays open across appends** (row 4) — walk-only, as for folds.
- **`> laravel.log` then an append** (row 6) — walk-only: the reread is pinned by
  `aShrunkLogIsReadAfresh`.
- **Typing in a small `.log` while a write lands** — walk-only and not walked: the race predates
  3b-vii (the typing-race ruling) and needs a keystroke inside one animation frame.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
