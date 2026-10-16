# 3a-i: the Git pane, read-only, and the Monaco diff host

**Date:** 2026-10-08
**Status:** design approved by the operator 2026-10-08, section by section
**Sub-phase:** 3a-i — the first of Phase 3's Git work, chosen by the operator 2026-10-08 ahead of
the editor and the chat and inbox adapters. 2c-vi (PM board) stays deferred. Waits on nothing.
**Mockups:** `.superpowers/brainstorm/11917-1791476776/content/git-pane-layout-v2.html`, option 1
("Spine") — throwaway, uncommitted

---

## Problem

Decision 7 says a project has N roots, and no surface in the app has ever shown more than the
first (phase log, 2026-09-16: *"the app goes on behaving as though N = 1 for the whole of
Phase 2"*). Design-language §11 promises a Git pane — *"Dedicated, multi-root. Changes grouped
by root; diff reuses the editor's Monaco diff renderer"* — and Decision 17 makes the editor
native Monaco. Neither exists, and nothing in the app hosts a web view.

Today seeing what changed across a project's roots means a terminal per root and `git status`
in each, and the agent's edits are invisible until asked about.

## How Phase 3's Git work is split

Agreed with the operator 2026-10-08. Each row gets its own spec, plan and walk.

| | Delivers | Exit |
|---|---|---|
| **3a-i** (this spec) | Git pane, read-only: changes by root, the Monaco diff host behind a `DiffRenderer` seam | below |
| **3a-ii** | Stage, unstage, commit — the fourth write to earn in under Invariant 6, with its price | commit from the pane by hand and by voice; it matches `git log` |
| **3a-iii** | A git account per organisation in Settings — a Wakil-generated SSH key held in the Keychain, the author identity — then push and pull | add a third org's key, push from its repo, the remote shows that identity |

Decisions taken for 3a-iii during this design, recorded here so its spec starts from them:
**credentials are Wakil-held per organisation, not the Mac's `~/.ssh/config` and `includeIf`
rules**, because Wakil already knows each root's organisation and git config has to infer it
from a URL pattern; and **the credential is an SSH key Wakil generates**, the public half shown
for pasting into GitHub or Bitbucket, the private half handed to a private per-push `ssh-agent`
and never written to disk.

## What the operator gets

1. **A `git` pane, opened like any other** (rail, ⌘P, voice, agent). It lists every root of the
   active project as a header — name, branch, ahead/behind against its local tracking branch —
   and under each the groups **Staged**, **Changes** and **Untracked**. An empty group is not
   drawn; a root with nothing reads `api · main · clean`.
2. **A partly staged file appears twice**: under Staged with the index-vs-HEAD diff, under
   Changes with the worktree-vs-index diff. What the next commit holds is always visible.
3. **Click or Return on a file drills in.** The diff fills the pane and the list folds into the
   **spine**: a 26 px column of status marks, one per file, grouped by root. The selected mark
   is outlined. **↑↓ step** through files across groups and roots without leaving the diff.
   **Esc unfolds** the list with the same file selected and in view.
4. **The diff is Monaco's**, read-only, inline (one column), themed from §5. Additions are §5
   green; deletions are a muted tone, **not** red, which §5 reserves for production and
   destruction.
5. **It is live.** An edit by the operator, the agent, or a terminal appears within about half a
   second with no refresh control. A `git add`, commit or branch switch elsewhere does too.

## What it does not do

- **No write of any kind.** No stage, commit, discard, checkout, fetch, push or pull. Invariant 6
  is untouched; 3a-ii and 3a-iii earn the writes.
- **No network.** Ahead/behind is against the local tracking ref as last fetched.
- **No side-by-side diff, no history, no branch graph** (§15 keeps the graph deferred).
- **No open-in-editor.** The editor does not exist; that click arrives with it.
- **No submodule descent.** A submodule is listed as one changed entry, as `git status` shows it.

## Design

### `wakil-git` — a capability (Invariant 10)

A new Go MCP server, `cmd/wakil-git`, the same shape as `cmd/wakil-db`: headless, `internal/mcpx`
framing, usable without Wakil.app. It runs the system `git` with `-C <root>`. Three tools:

| Tool | Returns |
|---|---|
| `git_status(root)` | branch (or detached SHA), upstream, ahead, behind; files with path, original path for a rename, and group (`staged`, `changed`, `untracked`) and status letter. One file may appear in two groups. Parsed from `status --porcelain=v2 -z --branch`. |
| `git_diff(root, path, side)` | `side` is `staged` or `changed`. Unified diff text, plus `binary`, `bytes`, `lines`, `truncated`. |
| `git_show(root, path, rev)` | `rev` is `HEAD` or `index`. The file's text at that side, for Monaco's original model, with the same size and binary fields. |

**Read-only by construction, not by policy:**

- A fixed allowlist of subcommands: `status`, `diff`, `show`, `rev-parse`. Any other is a
  programming error, refused before `exec`. (`for-each-ref` was dropped: no reader needs it, and
  its `%(signature)` format runs a signing program.)
- `path` is resolved against `root` and refused if it escapes it, symlinks included.
- Every call passes `--no-ext-diff --no-textconv -c core.fsmonitor=false -c core.hooksPath=/dev/null`
  and runs with `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, and a scrubbed environment. A
  repo's own config cannot make Wakil run a program, and a status never takes the index lock
  from the operator's terminal.
- Diffs are capped at 5,000 lines and files at 2 MB; past the cap the result says so (§8,
  *"a result that is still truncated admits it"*).

### The pane

- **Kind `"git"`**, registered in the five places every pane kind touches: `Pane.kinds`,
  `Pane.Contents` (new case `.git`, `rerunsSubjectOnRestore` true — a restored pane re-reads
  status), `paneView` in `Canvas.swift`, a new `GitPane.swift` in WakilApp, and
  `registerGitActions` called from `WakilWiring.build`.
- **State** in `PaneStore`, as `GitSnapshot`: the roots in project order, each with its status
  or its error; the selection `(root, path, side)`; `folded`; and a load mark per root and for
  the diff. `read_pane` returns it whole (Invariant 3).
- **Actions**, one path for operator and agent, each journalled: `git_select(root, path, side)`,
  `git_step(delta)`, `git_fold`, `git_unfold`. Step order is roots in project order, then Staged,
  Changes, Untracked, then path.
- **Roots.** `WindowModel.rootPath: String` becomes `rootPaths: [String]` from
  `ActiveContext.rootPaths`. Every existing consumer (the terminal's `term_open`, the
  no-project-root note) takes `rootPaths.first` and behaves exactly as today.

### The watcher

An FSEvents stream per root, owned by the pane's model, not by the view. It ignores
`.git/objects/`, `.git/logs/` and paths `git check-ignore` reports, but watches `.git/HEAD`,
`.git/index` and `.git/refs/` so staging and branch switches elsewhere arrive. Events coalesce
for 300 ms, then `git_status` re-runs for that root only; if the selected file's diff could have
changed, it re-fetches too. A stream is torn down when the pane closes or the project switches.

### The Monaco host — the seam the editor will reuse

- **`DiffRenderer`**, a protocol in WakilKit: `show(original:modified:language:)`, `clear()`,
  `scrollPosition` get/set. One conformance, `MonacoDiffRenderer` in WakilApp, a `WKWebView`.
- **Monaco is vendored**, minified, under `app/Resources/monaco/`, pinned by version and
  checksum, MIT-licensed. Loaded from the bundle with a `WKContentRuleList` blocking every
  non-`file:` request. No CDN, ever.
- One web view per Git pane, created on first drill-in and kept while the pane lives.
- Read-only, `renderSideBySide: false`, language from the file extension, theme from §5's
  tokens through `VoidPalette`.

### Voice

A new `IdentifierSource` contributes the Git pane's visible file paths to 2d-i's resolver, so
*"show me booking controller"* resolves to `api/app/Http/BookingController.php` and reaches
`git_select`. Voice adds no other path: design-language §12 makes voice a transport, not a command language.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How 3a-i meets it |
|---|---|
| 1 Confirm only what destroys | Nothing destroys; no confirmation exists. |
| 2 Enter never required | No input fields. |
| 3 New input focused | No input fields. |
| 4 Anything that waits can be cancelled | Selecting another file cancels the diff in flight; a root's status in flight is superseded by the next event. |
| 5 Work in flight shows it | A quiet load mark on the root header or the diff; a superseded request is cancelled, never queued twice. |
| 6 Stay where the operator was | Esc unfolds with the same file selected and in view. A refresh that removes the selected file moves the selection to the file now in its place; if none, the list unfolds with that root in view. A refresh that only changes the file keeps the diff's scroll position. |
| 7 Override or ignore; don't refuse | A root that is not a repository is listed as `not a git repository`, not hidden. Only an escaping path and a non-allowlisted subcommand are refused, by this spec's read-only construction. |
| 8 Errors whole, blocking only what they must | A root's git error is shown whole under its header; the other roots are unaffected. |
| 9 Defaults suggest | No defaults. |

Other edges: a binary file reads `binary · 2.1 MB`; an oversized file reads `file is 2.4 MB ·
first 2 MB shown`; a rename shows `old → new` with its diff; a detached HEAD shows the
short SHA in place of the branch; a root deleted from disk under the pane reads as its error.

**Amended (controller ruling R9).** The banner was `diff is <N> lines · first 5,000 shown`; it is now
`file is <size> · first 2 MB shown`, because Monaco diffs the two `git_show` texts, and those are
capped at 2 MB by bytes, so a line count is not what was cut. **R5:** `wakil-git` is agent-facing,
the agent reads and selects through it as the operator does. **R6:** a restored git pane re-reads
its status rather than trusting the saved snapshot.

## Testing

1. **Probe first, against the shippable artefact.** Task 1 renders a Monaco diff in a
   `WKWebView` inside the built `Wakil.app` with networking blocked, and records load time and
   bundle size growth. If it fails, stop and return to design before any pane code.
2. **Go, `wakil-git`**, against throwaway repos built per test: clean; partly staged (both
   groups); untracked; binary; over the line cap; renamed; detached HEAD; not a repository; a path
   escaping the root (refused); a repo whose config sets `core.fsmonitor` and a hook to a script
   that writes a marker file (the marker must never appear).
3. **WakilKit**, with fakes: `GitSnapshot` in `PaneStore`; step order across roots and groups;
   selection after refresh (rule 6, all three cases); a superseded diff is cancelled; the
   identifier source; `rootPaths.first` preserves every existing consumer. **A wiring test asserts
   the `wakil-git` client and the watcher are actually passed into `WindowModel`**, because
   never-wired injectables have shipped green before.
4. **Cover rung.** The e2e auditor covers, against a two-root fixture under `/tmp`: the list; drill
   in; the spine; ↑↓ across roots; Esc returns to the same file; an edit made outside the app
   appears; an error shown whole on one root while the other renders; the agent driving the same
   actions and reading the same state.
5. **The walk — the exit criterion:** *open a project with two roots; see each root's staged,
   changed and untracked files; step through their diffs from the spine by hand, by voice and
   through the agent; a change made in a terminal appears without a refresh.*

## Charter changes this sub-phase makes

- north-star §8: Phase 3's row gains 3a-i, 3a-ii and 3a-iii, 3a-i marked met on its walk.
- design-language §11, the Git row: *"diff reuses the editor's Monaco diff renderer"* becomes
  *"diff is rendered by the Monaco host 3a-i built, which the editor reuses"*; the spine is added.
- design-language §15: the side-by-side diff joins the deferred items.

## Open questions

None blocking. The FSEvents latency and the Monaco bundle size are measured by Task 1 and the
Go tests, not decided here.
