# 3a-ii: git writes from the Changes view — stage, unstage, discard, commit

**Date:** 2026-10-21
**Status:** design approved by the operator 2026-10-21, section by section; spec awaiting review
**Sub-phase:** 3a-ii, the next Git row of the phase map (3a-i met 2026-10-09). Follows 3b-ix
(main b2dd35b).

---

## Problem

The editor's Changes view (Decision 40) shows what changed in every root, and nothing in it
writes. Staging, committing or throwing a change away means a terminal per root, or asking the
agent, which spends a turn on `git add`. And a commit made anywhere carries whatever
`user.email` the repository or the global config holds, not the organisation's: the identity
slip Invariant 4's boundary exists to stop.

## Decisions the operator took during this design (2026-10-21)

- **The VS Code Source Control experience**, in the Changes view: a message box per root, ⌘⏎
  to commit, + / − / ↺ on rows and group headers, Commit All with nothing staged, Amend and
  Undo Last Commit, and the gutter peek's **Stage Change**.
- **Two sub-phases, one design.** 3a-ii is everything here. **3a-ii-b** is Stage Selected
  Ranges in the diff tab, which needs Monaco's diff editor to build a patch from a selection.
- **Discard is in, and the Trash is its undo.** The current file goes to the Trash before it
  is restored, so nothing is lost and no dialog asks (Rule 1), voice included.
- **Hooks run.** A commit from Wakil runs the repository's hooks and signing program, as a
  terminal or VS Code does. A failing hook's output is shown whole.
- **Approach A:** `wakil-git` gains write tools through a separate `GitWriter`; reads keep their
  guarantee that no repository-chosen program runs.
- **The author identity per organisation moves here from 3a-iii.** Settings → Organisation →
  Git holds a name and an email, and every commit from Wakil uses them. The SSH key, push and
  pull stay 3a-iii's.
- **No other git settings.** Every choice a toggle would make is fixed above.
- **The rest of VS Code's git experience is mapped, not dropped** (phase map, 2026-10-21):
  3a-iii signs in per organisation (an OAuth sign-in for GitHub, a Wakil-generated SSH key
  elsewhere) and pushes, pulls and fetches; 3a-iv brings branches and stash; 3a-v conflicts,
  history and blame.

## What the operator gets

1. **Each root header in the Changes view (⌘⇧G) has a message box** (several lines), a
   **Commit** button and a **▾** menu with *Amend Last Commit* and *Undo Last Commit*. ⌘⏎ in the
   box commits that root. With nothing staged the button reads **Commit All** and commits every
   change in the root, untracked files included. With an empty message the button is disabled
   and ⌘⏎ does nothing; the placeholder reads `Message (⌘⏎ to commit)`. **↑ in an empty box**
   steps back through that root's recent commit messages, as VS Code's does; ↓ steps forward.
2. **A file row, on hover,** shows **+** (stage) under Changes and Untracked, **−** (unstage)
   under Staged, and **↺** (discard) under Changes and Untracked. Each group header carries the
   same buttons for the whole group.
3. **Discard** moves the current file to the Trash as `confirm.go (discarded 14:02)`, then
   restores it from the index. A discarded untracked file goes to the Trash whole, as Move to
   Trash does (Decision 41). No dialog.
4. **The gutter peek** has **Stage Change** beside Revert: that one hunk is staged, and the file
   then shows under both Staged and Changes.
5. **Amend** replaces the last commit with what is staged and the box's message, or keeps the old
   message when the box is empty.
6. **Undo Last Commit** is a soft reset: the commit's changes go back to Staged and its message
   comes back into the box.
7. **A write in flight** shows a spinner on its control and cannot be pressed twice (Rule 5). A
   commit waiting on a slow hook has **Cancel** (Rule 4).
8. **Errors** — a failing hook, nothing to commit, a missing identity — show whole under the
   root's box, and the message is kept (Rule 8).
9. **It is live:** the list, the Files tree's letters and the gutter marks move together, from
   the window's one git status, re-read after each write.
10. **The agent and voice** use the same actions: "commit this as fix login" is an agent turn
    that calls `editor_changes_commit`.
11. **Settings → Organisation → Git**: **Name** and **Email**, saved when the field is left
    (Rule 2). The message box's hint names who will commit: `committing as you@example.com`, or
    `committing as you@personal.com (from git config)` when the organisation sets none.

## What it does not do

- **No push, pull, fetch or remote of any kind**, and no SSH key: 3a-iii.
- **No Stage Selected Ranges** in the diff tab: 3a-ii-b.
- **No branch create, switch or delete, no stash** (3a-iv), **no conflict actions, history or
  blame** (3a-v), **no rebase.**
- **No commit message drafting** by the quick model (Decision 42 keeps commit drafts an
  unscheduled candidate).
- **Not the agent's shell.** The organisation's identity reaches commits made through these
  actions. A `git commit` the agent runs in its own shell uses the repository's config, as today.
- **Not on the fast path**: its list stays navigation only.

## Design

### `wakil-git` — `GitWriter` (Invariant 10)

`GitRunner` stays as it is: reads only, with hooks, fsmonitor, external diff, signature
verification and the repository's own filters switched off.

Writes get **`GitWriter`**, beside it in `internal/wakilcore`, built with the same root check
(`NewGitRunner`'s: the path, symlinks resolved, must be a root of the active project) and the
same scrubbed environment (`gitScrubbedEnv`: no inherited `GIT_*`, no terminal prompt,
`GIT_NO_LAZY_FETCH=1`, `GIT_ALLOW_PROTOCOL=none`, the ceiling at the root's parent).

**What a write lets run**, because a real commit needs it: the repository's **hooks**, the
**signing program** under `commit.gpgsign`, and the repository's **clean filters** on `add`
(git-lfs and the like store the right object). **What it still blocks**: fsmonitor, pagers,
external diff, every network path, and any flag not on its list. Its pre-subcommand args are
`-c core.fsmonitor=false -c core.pager=cat -c diff.external= --no-pager`, and, when the
organisation sets them, `-c user.name=<name> -c user.email=<email>`.

| Tool | Runs | Allowed flags |
|---|---|---|
| `git_stage` | `git add -- <paths>` | none; paths after `--` |
| `git_unstage` | `git restore --staged -- <paths>` | none |
| `git_discard` | Trash each path (`fileops.go`'s Trash, renamed `<name> (discarded HH:MM)`), then `git restore -- <tracked paths>` | none |
| `git_stage_hunk` | `git apply --cached --unidiff-zero=false -` with a patch built from one hunk of `git diff -- <path>` | refused when the hunk's header is no longer in the file's current diff |
| `git_commit` | `git commit -F <tmp>`; with `all`, `git add -A -- .` first | `--allow-empty-message` never |
| `git_amend` | `git commit --amend [-F <tmp>] [--no-edit]` | |
| `git_undo_commit` | `git reset --soft HEAD~1`, and returns the undone commit's message | refused on a root commit |

- **Paths** are confined to the root as reads' are (`ResolvePath`): absolute or relative,
  symlinks resolved, never outside.
- **The message goes through a file** (`-F`, a temp file removed after), so no text in it is
  ever read as a flag, and it keeps its newlines.
- **Identity** is read from the active organisation's record (`LoadOrg`) at each write, so a
  change in Settings applies to the next commit without a restart.
- **A write is one git process at a time per root**, held by a per-root lock in the tool.
- **Errors** are git's words, whole, with the exit status; a hook's output is captured to 64 KB,
  keeping the end. A cancelled call kills git's process group, hooks included.

### Organisation identity — Go

- `Org` gains `GitName` and `GitEmail` (`json:"gitName,omitempty"`, `json:"gitEmail,omitempty"`).
- `ctx_update_org` takes `gitName` and `gitEmail` (omit to leave unchanged, `""` to clear); a
  value holding a newline is refused (it would end git's config value). Nothing else about an
  email is checked (Rule 7): git accepts what it accepts.
- `config_tree` returns both on `org`, and `identity`: what a commit would use, `{name, email,
  from: "organisation" | "git config"}` per root — read with `git config user.name/user.email`
  through `GitRunner` when the organisation sets none.

### Actions — WakilKit (Invariant 2)

Registered beside `editor_changes_select` and `editor_changes_step`, kind `.mutate`, audience
agent-reachable, **price *allow* everywhere** (Decision 25), so voice and the agent run them
(Invariant 7's allow exception):

| Action | Params |
|---|---|
| `editor_changes_stage` | `root`, `paths` or `group` (`changed`, `untracked`) |
| `editor_changes_unstage` | `root`, `paths` or `group` (`staged`) |
| `editor_changes_discard` | `root`, `paths` or `group` (`changed`, `untracked`) |
| `editor_changes_stage_hunk` | `path`, `hunk` (its `@@` header, as the peek shows it) |
| `editor_changes_commit` | `root`, `message`, `all` (default: true when nothing is staged) |
| `editor_changes_amend` | `root`, `message` (optional) |
| `editor_changes_undo_commit` | `root` |

- **After a write** the window re-reads that root's status at once (`GitStatus`), so the Changes
  view, the tree's letters and the gutter marks move together, before the watcher's wake.
- **One write per root in flight.** The window holds it; a second is refused with `a git write
  is already running in <root name>` (Rule 5). The control shows a spinner; Cancel cancels the
  dispatch, which kills git.
- **The message box's text is the window's, per root** (`changesMessages[root]`), kept when the
  view is left and the window relaunched like a draft (Rule 2); cleared after a commit succeeds,
  filled by Undo Last Commit.
- **Message history:** the last 20 messages committed from Wakil, per root, kept with the drafts.
  ↑ in an empty box (or one still showing a history entry) steps back, ↓ forward; typing leaves
  history. Nothing is read from `git log` for it.
- **The journal** records each write with its params; a message is kept whole, file contents
  never.
- **The commit hint** (`committing as …`) is read from `config_tree`'s `identity` for the root.

### WakilApp

- `EditorColumn`'s Changes view: the root header's box, Commit / Commit All, the ▾ menu; row and
  group hover buttons; spinners and Cancel; the error line under the box. Every control has an
  accessibility identifier (`editor.changes.<root>.commit`, `.message`, `.amend`, `.undo`,
  `editor.changes.<root>.<group>.stageAll` …, `editor.changes.row.<path>.stage` …).
- `monaco-host.html`'s peek: **Stage Change** beside Revert, posting back as Revert does.
- Settings → Organisation: a **GIT** section with Name and Email, saved on blur through
  `saveOrganisationField` (two new `OrganisationField` cases).

### Interaction rules

- **Rule 1:** nothing asks. Discard is recoverable from the Trash; a commit is undone by Undo Last
  Commit.
- **Rule 2:** the message box and the identity fields keep what was typed when focus leaves.
- **Rule 3:** the message box takes focus when the Changes view is opened by ⌘⇧G with nothing
  else focused in it.
- **Rule 4:** a commit (hooks) can be cancelled.
- **Rule 5:** one write per root, shown in flight.
- **Rule 6:** after any write the selection and scroll stay where they were; a row that moved
  group keeps its selection in the new group.
- **Rule 7:** a stage of a file already staged, or an unstage of one not staged, is a no-op, not
  a refusal. Refusals are the ones git or an invariant makes, and they say which.
- **Rule 8:** errors whole; a failed root does not block the others.
- **Rule 9:** Commit All is a default, shown on the button; staging first overrides it.

## Errors and edges

| Case | What happens |
|---|---|
| A hook fails | Nothing committed; its output whole under the box; the message kept |
| A hook waits for input | It has no terminal and reads EOF. One that never finishes is stopped by Cancel; no timeout |
| Signing needs a passphrase | The GUI pinentry asks, as for VS Code; with none configured, git's error is shown |
| A merge or a rebase in progress | Conflicted files show as today. Stage marks one resolved. Commit with an empty box concludes the merge with git's prepared message (`--no-edit` semantics through `-F .git/MERGE_MSG`) |
| No identity anywhere | Git's error, plus the fix: set Name and Email in Settings → Organisation → Git |
| Discard of a file open with unsaved edits | The tab keeps its buffer and shows the file changed on disk, as for any outside change |
| Stage Change after the file was edited again | Refused: `the change moved — open the peek again` |
| Undo Last Commit on a root commit | Refused: `nothing to undo: this is the first commit` |
| A path outside the root, a flag off the list | Refused before exec, naming it |
| No `git` binary | The read path's existing error |

## Testing

- **Go (`internal/wakilcore`, `cmd/wakil-git`, `cmd/wakil-ctx`):** each tool against a temporary
  repository; a path outside the root and an unlisted flag refused; a failing pre-commit hook
  (exit and output); a message starting with `-` and one with newlines; discard trashing then
  restoring, and an untracked file trashed whole; hunk staging, and the moved-hunk refusal; undo
  on a root commit refused; identity from the organisation, and from git config when unset; a
  newline in `gitEmail` refused; reads still run no hook (an existing test extended with a hook
  that would write a file).
- **WakilKit:** each action's params, kind and price; the status re-read after a write; one write
  per root; the message box kept, cleared and refilled; the commit hint's two forms.
- **e2e (seeded repository):** stage, commit, and `git log -1` showing the message and the
  organisation's identity; Commit All; discard landing in the Trash with the right name; Undo
  Last Commit refilling the box; a failing hook's output shown and the message kept; Stage Change
  from the peek; the identity fields saved on blur.
- **Runbook (`docs/wakil/phase-3a-ii-acceptance.md`):** a walk on a real repository, by hand and
  by voice, ending with `git log` checked in a terminal.

## Charter changes this sub-phase makes

- **Invariant 6:** the table gains *Stage, unstage, discard, commit — local git inside the
  project's roots | wakil-git | 2026-10-21*. The appendix entry: a commit stays on this Mac and
  Undo Last Commit reverses it; a discard's old copy is in the Trash; a commit runs the
  repository's hooks and signing program, no more than the agent's shell can, while every read
  still runs none.
- **Decision 43** (new): git writes from the Changes view, priced *allow*, hooks run, discard
  through the Trash, the organisation's author identity, range staging left to 3a-ii-b.
  *Reverse if:* a commit or discard from Wakil is found to have lost work that the Trash or Undo
  Last Commit could not bring back — then the price becomes *gate*.
- **Decision 40:** its last sentence becomes "Stage, unstage, discard and commit are 3a-ii's
  (Decision 43)."
- **Phase map:** rows added with this spec (2026-10-21): **3a-ii-b** (Stage Selected Ranges),
  3a-iii reworded (sign-in and the Keychain credential; the identity moved here), **3a-iv**
  (branches and stash) and **3a-v** (conflicts, history and blame). 3a-ii is marked met on its
  walk.
- **The 3a-i spec's split table** is left as written; Decision 43 records the move.
