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
g() { git -c user.name=seed -c user.email=seed@example.com "$@"; }
cd "$W/api" && git init -q -b main
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > confirm.go
printf 'alpha\nbeta\n' > notes.md
git add . && g commit -qm seed
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
<!-- /machine-walk -->
