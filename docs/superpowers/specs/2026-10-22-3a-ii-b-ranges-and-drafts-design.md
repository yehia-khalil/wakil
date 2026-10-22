# 3a-ii-b: Stage Selected Ranges in the diff tab, and a drafted commit message

**Date:** 2026-10-22
**Status:** written from the phase-map row at the operator's request (2026-10-22, no interview);
awaiting the operator's review
**Sub-phase:** 3a-ii-b, the row added by the 3a-ii design (2026-10-21). Follows 3a-ii (main
91f64b7, PR #41). Runs beside 2e-ii, which works in Settings → Organisation; nothing here touches
those files except one switch row under QUICK TASKS.

---

## Problem

3a-ii gave the Changes view VS Code's Source Control, with two pieces left over. Staging part of
a file needs a file tab, a gutter mark and its peek, one whole hunk at a time; the diff tab, where
the operator is actually reading the change, can stage nothing. Writing the message is the last
manual step of every commit, and Decision 42 has listed *commit drafts* as an unscheduled quick
task since 3b-viii.

The phase-map row: *Stage Selected Ranges in the diff tab; draft the commit message — ✨ in the
box (and an action), the quick model reads the staged diff, the operator commits.*

## Decisions already taken (the row, and the records it cites)

- **Stage Selected Ranges is in the diff tab** (3a-ii's split, Decision 43).
- **✨ sits in the commit box and is also an action.** The quick model (Decision 42: the org's
  `quickProvider`, otherwise the active provider) reads the staged diff and drafts. **The operator
  commits**: a draft is never committed by Wakil.
- **A quick task is a caller of `QuickTasks` with a prompt and a parser, and it has an on/off
  switch beside the model, per org** (Decision 42 and its 3b-ix amendment).
- **Every write goes through `GitWriter`**, guarded by the blob id of the text the change was
  computed from (3a-ii, ruling R1).

## What the operator gets

1. **In a Changes diff tab** (`confirm.go (Changes)`, the index against the working tree), select
   lines in the diff and press **Stage Selected Ranges**, a button in the tab's header strip that
   is enabled while the selection touches a change. The same command is in the diff's right-click
   menu and in ⌘K. Only the selected part of each change goes into the index. Afterwards the tab
   shows what is still unstaged, and the file appears under both Staged and Changes.
2. **With no selection**, the command stages the change under the caret: VS Code treats a caret
   as a one-line selection.
3. **In a commit box, ✨** (top right inside the box, `Draft Message`) asks the quick model for a
   message for what the Commit button would commit. That is the staged diff, or every change when
   the button reads Commit All. The draft lands in the box. The operator edits it and commits as
   in 3a-ii.
4. **While a draft is in flight**, ✨ shows a spinner, cannot be pressed again, and becomes ✕ to
   cancel (Rules 4, 5).
5. **Voice and the agent** have both actions: "stage the selection", and "draft a commit
   message" → `editor_changes_draft_message`.
6. **Settings → Providers → QUICK TASKS** gains a third switch, **Commit drafts**, beside
   Ghost-text and Fast path. It is on by default. Off hides ✨, and the action refuses with a
   message that names the switch.

## What it does not do

- **No Unstage Selected Ranges or Revert Selected Ranges.** The row names only Stage. Both would
  reuse `git_stage_hunk` (unstage writes the index text back toward HEAD), so they are cheap to
  add later. They are listed here so their absence is on the record.
- **No ranges in a file tab.** A file tab keeps the 3a-ii peek's Stage Change for one hunk.
- **No staging from a Staged or Untracked diff tab.** Staged is already staged. An untracked file
  has no index text, so there is nothing to stage part of; + on its row stages it whole.
- **No auto-commit, and no draft unless asked.** ✨ is pressed or the action is called. Nothing
  drafts on opening the view, on staging, or on idle.
- **No `git log` reading.** Style examples come from the root's own Wakil message history (3a-ii),
  not from git history. History is 3a-v's.
- **Not a draft of the agent's own `git commit`.** That is unchanged, as in 3a-ii.

## Design

### Stage Selected Ranges — pure, in WakilKit (`EditorHunks.swift`)

The diff tab already holds both texts. `GitDiffState.original` is the index text and `.modified`
is the working-tree text (`editorDiffRevs(.changed)`). Ranges are computed the way 3a-ii computes a
hunk: in Swift, from those two texts, with no patch and no `git apply`.

`editorStagedText(base:text:ranges:) -> String?`, beside `editorStagedText(base:text:hunk:)`:

- The hunks come from `editorHunks(base: original, text: modified)`.
- `ranges` are 1-based, inclusive line spans in the **modified** text: the selections Monaco
  reports from the diff's modified editor. A caret is a one-line span.
- **Per hunk, the intersection is staged:**
  - `added`: the added lines inside the ranges are staged, and the rest are left out.
  - `changed`: the new lines inside the ranges are staged. The hunk's old lines are removed from
    the index whenever any new line of the hunk is selected, because a changed hunk is a
    replacement and half a replacement reads as a duplicate. When none of its new lines are
    selected the hunk is untouched.
  - `deleted`: staged when a range covers the line its mark sits on (`editorGutterMarks`: the line
    above, or line 1 for a deletion at the top).
  - Hunks the ranges do not touch keep their index text.
- It returns nil when no hunk is touched. The action reads nil as `the selection holds no change`.

> **Builder's call, flagged:** whether the old lines of a partly selected `changed` hunk should go
> pairwise (old line *k* with new line *k*) instead of whole. Whole is VS Code's behaviour in the
> inline diff, where the removed lines show as a block that cannot be selected. Pairwise would
> need the side-by-side view.

### Selection — `monaco-host.html`

- `reportDiff()` posts `selection` (today `null`) as the modified editor's **selections**: every
  cursor, `[{startLine, endLine}]`. An end at column 1 of a later line does not count that line,
  which is the editor's convention for a whole-line drag. The report fires on
  `dme.onDidChangeCursorSelection`.
- The modified editor's context menu gains **Stage Selected Ranges** (`dme.addAction`, group
  `navigation`), shown only for a Changes diff. It posts `{type: 'stageRanges', key}`, and Swift
  answers as the header button does.
- The inline diff's removed lines are view zones and cannot be selected. A deletion is reached by
  its line, as above.

### Action — `editor_changes_stage_ranges` (`EditorChangesWrites.swift`)

| | |
|---|---|
| Params | `path` (absolute), `ranges` (`[{start, end}]`, optional: default is the diff tab's selection), `pane` (optional, as `editor_changes_stage_hunk`) |
| Kind / audience / price | `.mutate`, agent-reachable, ***allow* everywhere**: the same price as `editor_changes_stage_hunk` (Decision 43) |
| Texts | From the pane's **Changes diff tab** for `path` when one is open; otherwise both are read fresh with `git_show` (`index`, `worktree`), so the agent can stage by line numbers with no tab |
| Write | `git_stage_hunk` unchanged: `content` = `editorStagedText(…ranges:)`, `expect` = `gitBlobId(original)` |
| After | The root's status is re-read (3a-ii). The diff tab refreshes under the same key, so its cursor and scroll stay where they were (`wakilShowDiff`'s `same` path) |

- **One write per root** (3a-ii's `changesTasks`), with the spinner on the header button.
- **Refusals**, each named: the file is binary, or truncated at 2 MB (`gitDiffBanner`), and
  partial staging of a cut file would drop the rest; more than `editorHunksLineCap` lines, so no
  hunks; a conflicted file (`U`), whose index holds stages; a stale guard from Go (`the change
  moved — reopen the diff`, 3a-ii's words).

### Draft — `CommitDraft` (`WakilKit/App/CommitDraft.swift`), a quick task

Decision 42's shape: a prompt and a parser, called through `QuickTasks.respond`.

- **Input.** The text the Commit button would commit, read through `wakil-git`:
  - Something staged: `git_diff` with `side: staged` for the **whole root**. `git_diff` takes an
    empty `path` to mean the root (a Go change: `diffArg.Path` optional, and `GitDiff` runs
    `git diff --cached --no-color --` with no pathspec when it is empty). This is still a read
    through `GitRunner`.
  - Nothing staged (Commit All): `git_diff side: changed` for the root, plus each untracked
    file's path and line count from the window's `GitStatus`. Untracked contents are not sent.
  - **Cap:** at most 1,500 diff lines go to the model. Past that, every file still appears as one
    `path +a −d` line, and the prompt says the diff was cut.
  - **Style:** up to five of the root's last messages from Wakil's history (3a-ii's
    `changesHistory`), as examples of this repository's style. With none, the instructions ask
    for a short imperative subject line and an optional body.
- **Request.** `RespondRequest(instructions:, input:, jsonSchema: {"message": string},
  maxTokens: 300)`, with fallback on (unlike the fast path, a draft is worth waiting for).
- **Parser.** `message`, trimmed. An empty one is an error (`the model returned no message`).
- **Never sent:** the identity, the organisation's secrets, file contents outside the diff. The
  diff is the operator's code going to the org's own provider. That is the same reach as
  ghost-text, which already sends the buffer.

### Action — `editor_changes_draft_message`

| | |
|---|---|
| Params | `root` |
| Kind / audience | `.control`, agent-reachable. It fills Wakil's own box and changes nothing outside Wakil |
| Reply | `{message}`, which is also put in the box |
| Refusals | the org's **Commit drafts** switch is off (`commit drafts are off for <org> — Settings → Providers → Quick tasks`); no quick tasks built (the existing `QuickModelError.noProvider` words); nothing to commit (`nothing to draft from: <root name> has no changes`) |

**Where the draft lands (Rule 2: the box is the operator's):**

- With an empty box, the draft fills it.
- With text in the box, the draft replaces it, and **⌘Z in the box puts the replaced text back**:
  the replacement is registered as one undo step on the window's `UndoManager`. *My call:* VS
  Code replaces too, and a ✨ that refused when the box had text would break Rule 7.
- **Typing in the box while a draft is in flight cancels the draft.** The operator's keystrokes
  win, so nothing they typed is overwritten when the reply arrives.
- The draft clears the history cursor (3a-ii's ↑/↓). It is not added to history until it is
  committed.

### Go

- `Org` gains `CommitDrafts *bool` (nil is the default, on). `config_tree` sends it resolved, as
  `ghostText` and `fastPath`. `ctx_update_org` writes it.
- `git_diff`: `path` is optional, and empty means the whole root (above). The 5,000-line cap
  stays. The draft cuts its input at 1,500 lines on top of that.

### WakilApp

- **Diff tab header strip** (`EditorPane`): **Stage Selected Ranges**, shown on a Changes diff
  tab and enabled while the selection touches a hunk (computed in WakilKit from the reported
  selections). Identifier `editor.diff.stageRanges`.
- **Commit box** (`EditorColumn.commitBox`): ✨ inside the box's top-right corner. It becomes a
  spinner, and ✕ on hover, while drafting. `.help("Draft Message")`, identifier
  `editor.changes.<root>.draft`. Hidden when the switch is off, or when the root has nothing to
  commit (that root has no box anyway).
- **A failed draft** shows whole on the box's error line, under the box (3a-ii's), and the box
  keeps what it held.
- **Settings** (`QuickTaskSettingsForms`): a **Commit drafts** row, `settings.org.commitDrafts`,
  hint *Drafts a message from what you are about to commit, when you press ✨*.

### Interaction rules

- **Rule 1:** nothing asks. Staging ranges is undone with − (unstage) or by staging the rest. A
  replaced draft comes back with ⌘Z.
- **Rule 2:** the box keeps the operator's text. A draft replaces it only on their press, the
  replacement can be undone, and typing while a draft is in flight wins.
- **Rule 3:** no new input field. The box keeps 3a-ii's focus rule, and focus stays in the box
  after ✨.
- **Rule 4:** a draft can be cancelled with ✕, and a stage's dispatch through 3a-ii's Cancel.
- **Rule 5:** ✨ and Stage Selected Ranges show their work and cannot fire twice.
- **Rule 6:** after staging, the diff tab keeps its cursor and scroll. The Changes list keeps its
  selection (3a-ii).
- **Rule 7:** a selection that touches no change disables the button (it is not refused). Through
  the action it is a refusal that says why, because an agent's line numbers can miss.
  Binary/truncated/conflicted are refused, each naming why a partial stage would lose content.
- **Rule 8:** model and git errors show whole under the box or the tab. A failed draft blocks
  nothing; the operator can still write the message and commit.
- **Rule 9:** Commit drafts is on by default and can be switched off per org.

## Errors and edges

| Case | What happens |
|---|---|
| The file changed on disk after the diff was shown | The diff tab's texts are what the operator saw. The guard is the index blob, so a working-tree change does not refuse; the stage writes the selected lines as shown, and the refreshed tab shows the rest |
| The index moved since the diff was shown | Go refuses on `expect`: `the change moved — reopen the diff` |
| Multiple cursors | Each selection is a range, and their union is staged |
| A selection inside a hunk's context lines only | Touches no change: the button is disabled, and the action refuses |
| CRLF file | The hunk lines split on scalars (3a-ii); the staged text keeps the file's line endings |
| The quick model is unreachable | One fallback (Decision 42), then the error under the box |
| The provider is a session (`claude -p`) | It takes about 1–4.5 s (measured 2026-10-19); the spinner and ✕ cover it |
| The model returns prose or fences around JSON | Parsed by the existing `respond` JSON path. On failure the error is shown whole (`invalidReply`) |
| A huge staged diff | Cut at 1,500 lines, the rest as `path +a −d` lines |
| Only binary files are staged | The draft names them from the stat lines; the model sees no content |
| An org switch while drafting | The quick-tasks generation guard drops the reply (as ghost-text does), and the box is untouched |

## Testing

- **WakilKit, pure:** `editorStagedText(…ranges:)` for each hunk kind; a partial `added`; a
  `changed` with one new line selected (all old lines go); a deletion touched by its mark line; a
  caret; multiple ranges; context only → nil; CRLF. A round trip: stage the ranges, then diff the
  index against the working tree, and only the unselected changes remain.
- **WakilKit, actions:** `editor_changes_stage_ranges` takes the tab's texts and `expect`, reads
  fresh with no tab, refuses binary, truncated, conflicted, over the cap, and no-change, and has
  its kind and price. `editor_changes_draft_message` covers the switch off, an empty and a full
  box (⌘Z restores), typing during the draft cancelling it, the generation guard, and the input
  cap with the stat lines. `CommitDraft`'s prompt is built from staged and from Commit All, and
  its parser is checked.
- **Go:** `git_diff` with an empty path over a root with two staged files; `CommitDrafts`
  round-trips through `ctx_update_org` and `config_tree`, default on.
- **e2e (seeded repository):** select two lines of a three-line added hunk in a Changes diff,
  stage, and `git diff --cached` shows just those two. Caret staging. The right-click menu entry.
  ✨ against a seeded local quick provider (a stub `respond` endpoint) fills the box, then commit.
  The switch off hides ✨.
- **Runbook (`docs/wakil/phase-3a-ii-b-acceptance.md`):** on a real repository, stage parts of
  two files by selection, draft with ✨ on the org's real quick provider (local and Same as
  agent), edit, and commit; check `git log -p -1` in a terminal.

## Charter changes this sub-phase makes

- **Decision 42:** *commit drafts* moves from the unscheduled candidates to built (3a-ii-b), with
  its switch beside Ghost-text and Fast path.
- **Decision 43:** its last sentence, "**Stage Selected Ranges** in the diff tab is left to
  3a-ii-b", becomes "…came in 3a-ii-b, through the same `git_stage_hunk` and guard".
- **Invariant 6:** no change. Range staging is a stage, already on the table from 2026-10-21.
- **Phase map:** 3a-ii-b is marked met on its walk.
