# 3a-v-a History and Blame Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator sees a file's history in a Timeline under the Files tab and opens any commit's change to it as a diff, and reads who last changed the cursor's line, when and why, at the end of that line — VS Code's Timeline and inline blame; the agent reads both as tools.

**Architecture:** `internal/wakilcore` gains two reads (`ReadFileHistory`, `ReadBlame`) and two `GitShow` sides (`commit:`, `commit-parent:`) behind the existing read runner, whose allowlist learns `blame` and a few `log` flags and which learns to feed stdin; `wakil-git` exposes `git_file_history` and `git_blame`; WakilKit adds the parsed types, a `.diff` subject for a commit, and the actions `editor_timeline`, `editor_blame`, `editor_open_commit_diff`; WakilApp draws the Timeline section and the blame decoration in `monaco-host.html`, switched by a new app-tier setting. No write is added.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-git`), Swift 6 / SwiftUI, Swift Testing, Monaco in `app/Sources/WakilApp/monaco-host.html`.

**Spec:** `docs/superpowers/specs/2026-10-23-3a-v-conflicts-history-blame-design.md` (this plan builds its *3a-v-a*; *3a-v-b, conflicts* is a later plan)

## Global Constraints

- Reads only: every git call goes through `GitRunner.Run` (or the new `RunInput`), with `gitSafetyArgs`; no repository-chosen program runs. Signature formats stay refused.
- Commit ids passed to `git_show` sides are 40-hex only (`^[0-9a-f]{40}$`), as the stash sides.
- Exact copy:
  - Timeline header `Timeline`, with the file's name after it in the dim style: `Timeline · a.txt`
  - empty: `No history for this file.`
  - top row when the file differs from HEAD: `Uncommitted changes`
  - paging row: `Load more`
  - row menu: `Copy Commit ID`, `Copy Commit Message`
  - commit diff tab title: `a.txt (abc1234)` (the file's name at that commit, the short id)
  - blame annotation: `<author>, <age> • <subject>`; uncommitted: `Not committed yet`
  - blame hover actions: `Open Changes`, `Copy Commit ID`
  - setting: Settings → Editor → Editing, row `Inline blame`, options `Off` / `On`, default `On`
- Ages (`editorRelativeAge`): `just now` (< 60 s), `1 minute ago` / `N minutes ago`, `1 hour ago` / `N hours ago`, `1 day ago` / `N days ago` (< 14 days), `N weeks ago` (< 60 days), `N months ago` (< 730 days), `N years ago`. The Stashes group's own short ages are left as they are.
- Paging: 50 commits a page.
- Blame deadline: 10 s; past it, or on any error, blame shows nothing and says nothing.
- Identifiers: `editor.timeline` (section), `editor.timeline.toggle`, `editor.timeline.uncommitted`, `editor.timeline.row.<id7>`, `editor.timeline.more`, `settings.editor.inlineBlame.<Off|On>`, `settings.editor.inlineBlame.refusal`.
- Every new action/tool updates the pinned lists: `AppWiringTests`, `WindowModelPaletteTests` (`registeredBeforeThePalette`, `agentToolsBeforeThePalette`), `StandardActionsTests` (names and `paramsByAction`), `ActionClassificationTests`, `cmd/wakil-git` `main_test.go` tool list, `InvalidationContractTests` for new `WindowModel` properties.
- Public repository: example names only (Ada Lovelace, initech, umbrella) in committed text.

## Rulings

- **R1 — Blame is fetched per tab text, not per cursor move.** On tab activation, after a save, and 500 ms after the text stops changing; the cursor only picks a line from what was fetched. Cost if wrong: an extra git call per pause in typing.
- **R2 — The Timeline follows the focused editor pane's active tab.** A file tab, or a diff tab (changes, stash or commit), gives its path and root; a scratch tab, no tab, or a path outside a git root gives `No history for this file.` Cost if wrong: the Timeline goes blank on a diff tab, which VS Code does not do.
- **R3 — A merge commit's row diffs against its first parent**, as `git log` and VS Code do.
- **R4 — The Timeline's open/closed state is a per-viewer convenience** (`@AppStorage("editor.timeline.open")`, default open), not a setting.

## Review Focus

1. **A file renamed in its history** — rows older than the rename open the diff under the old path, both sides present. Test in Task 1.
2. **An unsaved tab with lines inserted above the cursor** — blame names the right commit for each line, and an inserted line reads `Not committed yet`. Test in Task 2.
3. **The commit that added the file** — its diff's left side is absent, not an error. Tests in Tasks 1 and 4.
4. **A path with spaces or non-ASCII letters** — history and blame read it whole (`-z`, NUL-separated). Test in Task 1.
5. **Switching tabs while a blame is in flight** — the late reply never decorates the tab now shown. Test in Task 5.

---

### Task 1: Go — file history and the commit sides

**Files:** Modify `internal/wakilcore/gitread.go` (`gitAllowedFlags["log"]` gains `--follow`, `--max-count=`, `--skip=`, `--name-status`; the refusal text at `Run` lists every subcommand), `internal/wakilcore/gitdiff.go` (`commit:<sha>`, `commit-parent:<sha>[:<path>]`). Create `internal/wakilcore/githistory.go`. Test: `internal/wakilcore/githistory_test.go`, `internal/wakilcore/gitdiff_test.go`.

**Interfaces:** Produces
- `type GitCommit struct { ID string; Parents []string; Author, Email string; Date time.Time; Subject, Body, Path string }` (json `id, parents, author, email, date, subject, body, path`; `Path` is the file's name at that commit).
- `func ReadFileHistory(ctx context.Context, g *GitRunner, path string, skip, count int) ([]GitCommit, error)` — newest first; `count` 0 means 50; `git log --follow --name-status -z --format=<NUL-separated fields> --skip= --max-count= -- path`.
- `GitShow(ctx, g, path, "commit:<sha>")` — the file at that commit; `"commit-parent:<sha>"` — the file at `<sha>^1`, with an optional `:<old path>` suffix when the name differed there; a root commit or a missing path returns `Absent: true`.

- [ ] **Step 1: Failing tests** (fixture via the existing `branchFixture` helpers):
  - `TestFileHistoryNewestFirstWithAuthorAndSubject`: three commits to `a.txt` → three rows, newest first, `Author == "seed"`, subjects in order, `Path == "a.txt"`.
  - `TestFileHistoryFollowsARename`: commit `old name.txt`, `git mv` to `café.txt`, commit an edit → history of `café.txt` has both, the older row's `Path == "old name.txt"`.
  - `TestFileHistoryPages`: 3 commits, `skip 1, count 1` → exactly the middle one.
  - `TestFileHistoryOfAnUntrackedFileIsEmpty`: `[]`, no error.
  - `TestGitShowCommitSides`: `commit:<id>` text is the file after the commit; `commit-parent:<id>` is before it; for the adding commit `commit-parent:<id>` → `Absent`; `commit:HEAD` → refused (40-hex only); `commit-parent:<id>:old name.txt` reads the old path.
  - `TestLogFlagsStayFenced`: `g.Run(ctx, "log", "--output=x")` refused; `--follow` allowed.
- [ ] **Step 2: Run** `go test -count=1 ./internal/wakilcore -run 'FileHistory|GitShowCommit|LogFlags'` — Expected: FAIL (`ReadFileHistory` undefined).
- [ ] **Step 3: Implement** as the Interfaces say. Parse records by NUL; the `--name-status` entry after each commit gives the path (`R…` entries give the new and old names).
- [ ] **Step 4: Run** the same command, then `go test -count=1 ./internal/wakilcore` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-v-a: Go reads a file's history and its commits' sides`.

### Task 2: Go — blame of the tab's text

**Files:** Modify `internal/wakilcore/gitread.go` (`gitReadSubcommands["blame"]`; `gitAllowedFlags["blame"] = {"--porcelain", "--contents=", "--"}`; `func (g *GitRunner) RunInput(ctx, stdin []byte, sub string, args ...string) ([]byte, error)` — `Run` with stdin, same checks; `Run` calls it with nil). Create `internal/wakilcore/gitblame.go`. Test: `internal/wakilcore/gitblame_test.go`.

**Interfaces:** Produces
- `type GitBlameLine struct { Line int; ID, Author string; Date time.Time; Subject string }` (json `line, id, author, date, subject`); an uncommitted line has `ID` of forty `0`s.
- `func ReadBlame(ctx context.Context, g *GitRunner, path string, text *string) ([]GitBlameLine, error)` — `blame --porcelain [--contents=-] -- path`, `text` on stdin when given; one entry per line, in order; 10 s deadline inside.

- [ ] **Step 1: Failing tests:**
  - `TestBlameNamesEachLinesCommit`: two commits by different authors (`-c user.name=Ada Lovelace`), each changing one line → lines carry the right ids, authors and subjects.
  - `TestBlameOfUnsavedTextShiftsLines`: pass text with a new line inserted at the top → line 1 is all-zero id, line 2 carries what was line 1's commit.
  - `TestBlameOfAnUntrackedFileFails`: an error, nothing panics.
  - `TestBlameFlagsStayFenced`: `blame --output=x` and `blame -s` refused; `RunInput` refuses what `Run` refuses.
- [ ] **Step 2: Run** `go test -count=1 ./internal/wakilcore -run 'Blame'` — Expected: FAIL.
- [ ] **Step 3: Implement.** Porcelain gives each commit's headers once; carry them to later lines of the same commit.
- [ ] **Step 4: Run** the command, then `go test -count=1 ./internal/wakilcore` — Expected: PASS.
- [ ] **Step 5: Commit** `3a-v-a: Go blames a file's text, saved or not`.

### Task 3: wakil-git — the two read tools

**Files:** Modify `cmd/wakil-git/main.go` (tools beside `git_stashes`; `git_show`'s description names the commit sides), `cmd/wakil-git/main_test.go` (tool list). Test there.

**Interfaces:** Consumes Tasks 1–2. Produces tools
- `git_file_history {root, path, skip?, count?}` → `{commits: [GitCommit]}`;
- `git_blame {root, path, text?}` → `{lines: [GitBlameLine]}`.
Both "Read-only." in their descriptions; `path` relative to `root`.

- [ ] **Step 1: Failing test** — add both names to the pinned tool list; `TestGitFileHistoryTool` and `TestGitBlameTool` call them over the in-process server against a fixture and check one field each (`commits[0].subject`, `lines[0].author`).
- [ ] **Step 2: Run** `go test -count=1 ./cmd/wakil-git` — Expected: FAIL.
- [ ] **Step 3: Implement**, as `git_stashes` is wired.
- [ ] **Step 4: Run** `go test -count=1 ./cmd/wakil-git && make -s build` — Expected: PASS, build 0.
- [ ] **Step 5: Commit** `3a-v-a: wakil-git serves a file's history and blame`.

### Task 4: WakilKit — the types, the commit diff, the actions

**Files:** Create `app/Sources/WakilKit/Git/GitHistory.swift`. Modify `app/Sources/WakilKit/Editor/EditorSnapshot.swift` (`.diff(root:path:group:stash:commit:)`, `commit: GitCommitRef? = nil`), `app/Sources/WakilKit/Editor/EditorRenderer.swift` (`editorTabKey` for a commit: `diff:commit@<id>:<root>/<path>`), `app/Sources/WakilKit/Editor/EditorActions.swift` (`tabDiff` reads `commit`; `fetchDiff` uses `editorCommitDiffRevs`; `openCommitDiff`; the three actions). Test: `app/Tests/WakilKitTests/GitHistoryTests.swift`, plus the pinned lists.

**Interfaces:** Produces
- `public struct GitCommitInfo: Codable, Sendable, Equatable, Identifiable { id, parents, author, email, date: String, subject, body, path }`; `public struct GitBlameInfo: Codable, Sendable, Equatable { line: Int, id, author, date, subject }` with `var uncommitted: Bool` (all-zero id).
- `public struct GitCommitRef: Codable, Sendable, Hashable { id: String; path: String; parentPath: String? }`.
- `public func editorCommitDiffRevs(_ c: GitCommitRef) -> (original: String, modified: String)` → `("commit-parent:<id>[:<parentPath>]", "commit:<id>")`.
- `public func editorRelativeAge(_ iso: String, now: Date) -> String` (the copy in Global Constraints).
- `public func editorBlameText(_ b: GitBlameInfo, now: Date) -> String` → `Ada Lovelace, 3 days ago • Seed the search page` or `Not committed yet`.
- `public func editorCommitTabTitle(path: String, id: String) -> String` → `a.txt (abc1234)`.
- Actions (`kind: .read`, `.agentReachable`, allow): `editor_timeline {path?, skip?}` → the focused tab's (or `path`'s) commits; `editor_blame {path?, line?}` → lines (or one). `editor_open_commit_diff {root, path, commit, parentPath?}` (`kind: .control`), focusing an existing tab with the same subject, else a pinned read-only tab, as `openStashDiff`.

- [ ] **Step 1: Failing tests** (`GitHistoryTests`):
  - `relativeAges`: 30 s → `just now`; 61 s → `1 minute ago`; 3 h → `3 hours ago`; 3 d → `3 days ago`; 20 d → `2 weeks ago`; 90 d → `3 months ago`; 800 d → `2 years ago`.
  - `blameTextReadsLikeVSCode` and `anUncommittedLineSaysSo`.
  - `commitDiffSides`: with and without `parentPath`.
  - `aCommitTabHasItsOwnKeyAndTitle`: two commits of one file → two keys; title `a.txt (abc1234)`.
  - `openCommitDiffFocusesAnOpenTab`: open twice → one tab.
  - Pinned lists gain `editor_timeline`, `editor_blame`, `editor_open_commit_diff`.
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter GitHistoryTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, then `make app-test` — Expected: PASS (pre-existing `TestEveryAuditedControlIsNamed` and `docs-check` failures aside, which are Go/docs, not this suite).
- [ ] **Step 5: Commit** `3a-v-a: WakilKit reads history and blame and opens a commit's diff`.

### Task 5: Inline blame in the editor, and its setting

**Files:** Modify `internal/wakilcore/editorsettings.go` (`EditorAppSettings.InlineBlame *bool`, default on, as `ShowIgnored`), `app/Sources/WakilKit/Panes/SettingsTree.swift` (`inlineBlame: Bool = true`), `app/Sources/WakilApp/EditorSettingsForms.swift` (the `Inline blame` row in Editing), `app/Sources/WakilApp/monaco-host.html` (`wakilSetBlame(key, line, text, hover)` / clear: an `after` decoration on that line, dim, a gap before it; hovering shows subject, body, author, date and short id with **Open Changes** and **Copy Commit ID**, posting `blame {key, op: "open"|"copy", id}`), `app/Sources/WakilApp/MonacoEditorRenderer.swift` + `app/Sources/WakilKit/Editor/EditorRenderer.swift` (the step and the `onBlame` message), `app/Sources/WakilApp/EditorPane.swift` (fetch per R1 through a `blameFor` closure; on each `view` report send the cursor line's text; a generation per tab key so a late reply for another key is dropped), `app/Sources/WakilApp/Canvas.swift` (wiring). Test: `internal/wakilcore/editorsettings_test.go`, `app/Tests/WakilKitTests/GitHistoryTests.swift` (`EditorBlameCache`).

**Interfaces:** Consumes Task 4. Produces `public struct EditorBlameCache` in `GitHistory.swift`: `mutating func begin(key: String) -> Int` (a generation), `mutating func land(key: String, gen: Int, lines: [GitBlameInfo]) -> Bool` (false when stale), `func line(key: String, _ n: Int) -> GitBlameInfo?` — the pane keeps one; shown only for a writable file tab whose path is in a git root, never diff, read-only, scratch, untracked or binary tabs, and only while `inlineBlame` is on.

- [ ] **Step 1: Failing tests:** Go `TestInlineBlameDefaultsOnAndPatches`; Swift `aLateBlameForAnotherTabIsDropped` (begin A, begin B, land A's old gen → false, `line(A,1) == nil`), `aBlameLandsForItsTab`.
- [ ] **Step 2: Run** `go test -count=1 ./internal/wakilcore -run InlineBlame` and `cd app && ../scripts/swift-test.sh --filter GitHistoryTests` — Expected: FAIL.
- [ ] **Step 3: Implement**, the page decoration last; `Open Changes` opens `editor_open_commit_diff` for that line's commit (`parentPath` from the history is not needed here; the blame's path is the current one).
- [ ] **Step 4: Run** both, then `make app-test && make -s app-bundle` — Expected: PASS, bundle 0. Launch the bundle against a fixture repo, open a tracked file, move the cursor: the annotation follows the line; Settings → Editor → Inline blame Off removes it.
- [ ] **Step 5: Commit** `3a-v-a: inline blame on the cursor's line, with its setting`.

### Task 6: The Timeline under Files

**Files:** Create `app/Sources/WakilApp/EditorTimeline.swift`. Modify `app/Sources/WakilApp/EditorColumn.swift` (the section at the bottom of the `.files` case, collapsible header always visible, rows in their own scroll), `app/Sources/WakilKit/App/WindowModel.swift` or a new `WindowModel+History.swift` (`editorTimeline(root:path:skip:) async -> [GitCommitInfo]?` over `git_file_history`; the focused tab's `(root, path)` per R2), `app/Sources/WakilApp/Canvas.swift`. Test: `app/Tests/WakilKitTests/GitHistoryTests.swift` (`timelineSubject`, `timelineRows`).

**Interfaces:** Consumes Task 4. Produces `public func editorTimelineSubject(_ tab: EditorTab?) -> (root: String, path: String)?` (R2) and `public func editorTimelineRows(_ commits: [GitCommitInfo], uncommitted: Bool, more: Bool) -> [EditorTimelineRow]` with `enum EditorTimelineRow: Equatable { case uncommitted, commit(GitCommitInfo), more }`.

- [ ] **Step 1: Failing tests:** `timelineFollowsFileAndDiffTabs` (file tab, changes diff, stash diff, commit diff → their path; scratch, nil → nil); `timelineRowsPutUncommittedFirstAndMoreLast`; `fiftyMeansThereMayBeMore` (`more` only when the page came back full).
- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter GitHistoryTests` — Expected: FAIL.
- [ ] **Step 3: Implement.** Reload when the subject changes and when the root's status changes (after a commit), a spinner in the header while loading, a new subject cancelling the old load (Rules 4, 5); `uncommitted` when the root's status lists the path or the tab is dirty, opening the existing changes diff; a commit row opens `editor_open_commit_diff` with `parentPath` when the row before it (older) has another `path`; tooltip with full message, author, email, date, id; context menu `Copy Commit ID` / `Copy Commit Message` to the pasteboard; R4 for open/closed.
- [ ] **Step 4: Run** the filter, `make app-test`, `make -s app-bundle` — Expected: PASS. Launch and check a row opens `a.txt (abc1234)` with both sides.
- [ ] **Step 5: Commit** `3a-v-a: the Timeline under Files`.

### Task 7: Runbook and charter

**Files:** Create `docs/wakil/phase-3a-v-a-acceptance.md` (setup script on the 3a-iv runbook's pattern: a repo with a renamed file, two authors, an added-later file; then at most ten steps in a `# | Where | Do | Expect | Walked` table covering the Timeline rows, paging, the rename, the uncommitted row, the copy menu, blame on a moved cursor, an unsaved inserted line, the hover's Open Changes, the setting, and the agent asking "who last changed line 2 of a.txt"). Modify `docs/wakil/north-star.md` (Invariant 6's table gains 3a-iv's missing branches-and-stash row, spec call 11; 3a-v-a adds no write).

- [ ] **Step 1: Write the runbook; run its setup once on this Mac.** Expected: exit 0.
- [ ] **Step 2: Run** `scripts/public-check.sh` — Expected: passes.
- [ ] **Step 3: Commit** `3a-v-a: runbook, and Invariant 6 lists 3a-iv's write`.
