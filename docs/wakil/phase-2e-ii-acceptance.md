# 2e-ii — projects and environments from Settings: acceptance

**Spec:** [`2026-10-22-2e-ii-projects-environments-design.md`](../superpowers/specs/2026-10-22-2e-ii-projects-environments-design.md)
· **Charter:** Decision 21 (amended 2026-10-22), Decision 30, Decision 41, Invariant 5

The exit criterion, from the spec: in Settings the operator adds, renames and removes a project
and an environment without a dialog and without editing `project.json`. Renames follow the
active place everywhere it shows. A project or environment an agent is running in refuses to
move, and says which agent.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the repo root, on this Mac, after `make build` and `make app-bundle`. It is safe to
re-run.

```bash
(
set -e
ORG=personal
W="$TMPDIR/walk-2e-ii"
rm -rf "$W"
mkdir -p "$W/alpha" "$W/spare" "$W/project"
cat > "$W/project/project.json" <<J
{"name":"walk-2e-ii","org":"$ORG","roots":[{"path":"$W/alpha"}],"scopes":{},"environments":{"staging":{"databases":[],"api":[]},"qa":{"databases":[],"api":[]}}}
J
./bin/wakil project rm walk-2e-ii --org "$ORG" || true
./bin/wakil project add walk-2e-ii --path "$W/project/project.json" --org "$ORG"
echo "spare folder to add: $W/spare"
)
```

`walk-2e-ii` has two environments, `staging` and `qa`. `$TMPDIR/walk-2e-ii/spare` is an empty
folder the picker will add in row 1.

Launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil` from the repo root, make
`walk-2e-ii` active with ⌘P and `staging` the environment, and open Settings (⌘,). Keep a
Terminal window open for rows 4, 9 and 13. Clear the Trash of any `project.json (before removing …)` first.

## 1. The walk

Walk in order, in `personal`.

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Under PROJECTS click **+ Add a project**. In the folder picker (⇧⌘G, paste the `spare` path from setup) choose `spare` and press **Add** | The picker is the system one. `spare` appears in the tree; its page opens with **Name** focused and the text selected (Rule 3); the active project is still `walk-2e-ii` (Rule 6) | |
| 2 | Cancel the picker the next time you open it | Nothing happens: no new row, no message | |
| 3 | Type `spare-renamed`, click `walk-2e-ii` in the tree (no Return) | The tree shows `spare-renamed`; the project switcher (⌘P) lists it too. Saved on leaving the field (Rule 2) | |
| 4 | In Terminal: `cat "$TMPDIR/walk-2e-ii/spare/.wakil/project.json"` | The file's `name` is `spare-renamed` and its `roots` hold the `spare` folder | |
| 5 | On `spare-renamed`'s page press **Remove from this organisation** | The tree selects the PROJECTS heading; the line `Removed spare-renamed from this organisation — its folder is untouched.` shows; no dialog. `ls "$TMPDIR/walk-2e-ii/spare/.wakil"` still lists `project.json` | |
| 6 | **+ Add a project** again, choose `spare` | It comes back whole: the same name as in the file, `spare-renamed`; no second row | |
| 7 | Under `walk-2e-ii` click **+ Add an environment** | `new-environment` appears, its page opens with Name focused and selected, `Databases 0` and `API 0` | |
| 8 | Click **+ Add an environment** again, then rename it `qa` and press Return | A refusal whole under the field, naming the clash; the field keeps `qa` (the typed text is still in it); nothing is written | |
| 9 | Rename the first one `review` (type, then click `staging`). Then make `staging` the active environment, rename it `uat` and leave the field | The tree, the place line, the environment chip (**UAT**) and the switcher all show `uat`. The panes you had open in `staging` are back (the layout moved with the name) | |
| 10 | Make `qa` active, open a terminal pane in it, then on `uat` press **Remove environment** | The tree selects the project; the receipt reads `Removed uat — a copy of project.json is in the Trash`; no dialog. The window stays on `qa` with its panes | |
| 11 | In Finder open the Trash, select `project.json (before removing uat HH:MM)`, choose **Put Back** | The file returns to `$TMPDIR/walk-2e-ii/project/` as `project.json` and holds `uat`. Put Back is the undo | |
| 12 | Make `qa` active and remove it | The window lands on the first remaining environment, or shows none if none remain; nothing crashes | |
| 13 | Start an agent in `walk-2e-ii`@`review` from the composer, then in Settings try to rename `review` and to remove it | Each is refused whole, naming Invariant 5 and the agent. Stop the agent; the same rename now saves | |
| 14 | In the composer: `rename the project walk-2e-ii to walk-voice`, Return. Then hold ⌥, say the same sentence, release | The agent says it can't (the actions are operator-only); the name is unchanged. Voice reaches the agent, so it is told the same | |
| 15 | Type an empty name, then `a/b`, in a project's Name and press Return | `a name cannot be empty`, then the `/` refusal; the field keeps what was typed | |

## 2. Known and not fixed

- **Renaming a project drops a `project.json` key this build doesn't know.** `SaveProject`
  writes only the keys it knows; a hand-edited file loses an unknown one on rename. Known keys,
  roots and environments are kept.
- **A removed environment's copy is the only undo.** Trash emptied, nothing restores it.

## 3. Residue: what the walk cannot establish

- **The folder picker** (rows 1, 2, 6) is the system's `NSOpenPanel`; the harness can't drive
  it, so the checks register a folder with `ctx_create_project` and the walk presses the real
  button.
- **Put Back** (row 11) and the Trash's file name are Finder's; no check reads the Trash. The
  checks that remove an environment put a real file in the Trash of the Mac they run on.
- **Rule 3 on create** (row 1, 7): where the text cursor lands is not in the accessibility
  tree the checks read.
- **The agent-pin refusal** (row 13) needs a running agent in that place, a real provider and
  quota. The refusal itself is pinned in the Swift and Go tests.
- **Voice** (row 14) runs a real provider; the checks dispatch the same actions on the
  agent's socket and the walk hears the agent say it can't.
- **The field keeping what was typed** is asserted in the tree as the field's `Value:` line (the accessibility value of the text field), which only the field carries; row 15 is the walk's look at it.
- **A refused name on leaving the field** (row 8) is visible only until the page changes; the
  checks pin the refusal on Return and the unchanged tree after leaving.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

Not yet generated: run `make e2e`, then `make e2e-runbook`, on the head that merges.

<!-- /machine-walk -->
