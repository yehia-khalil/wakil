# 3b-iii: the Changes view, diff tabs, gutter marks and the peek — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Git pane folds into the editor. The left column gains a third view, **Changes** (⌘⇧G).
Its rows open **read-only diff tabs** in the editor's own web view. A file tab in a repository shows
**gutter marks** against the index. Clicking a mark opens an **inline peek** with previous, next and
**Revert**. The Files tree shows each changed file's status letter. The agent drives all of it
through actions (Invariant 2).

**Architecture:**
- **Go: nothing.** `wakil-git`'s `git_status` and `git_show` already answer everything.
- **WakilKit: one git status for the window.** A new actor, `GitStatus` (`Git/GitStatus.swift`),
  reads `git_status` once per root per watcher wake. The editor actions, the window's mirror
  (`WindowModel.gitRoots`), the vocabulary (`GitSource`) and ⌘P's changed files all read it. The git
  watcher runs while any editor pane is open.
- **WakilKit: the editor gains the rest.**
  - `Editor/EditorChanges.swift`: the Changes rows, step, highlight, and the tree's letter.
  - `Editor/EditorDiff.swift`: diff tabs, their fetch, and when ⌘⏎ may open the file.
  - `Editor/EditorHunks.swift`: `editorHunks`, the gutter marks, the peek and Revert.
  - `EditorActions.swift`: the new actions.
  - `EditorRenderer.swift`: `showDiff`, marks and the peek as render steps.
- **WakilKit: the Git pane kind is deleted.** A saved Git pane loads as an editor pane on Changes
  (`layoutMigratingGitPanes`).
- **WakilApp draws.** `monaco-host.html` hosts the code editor and a diff editor in one page per pane.
  `MonacoDiffRenderer`, `GitPane.swift` and `--probe-monaco` are deleted. `EditorColumn` draws
  Changes, and the tree row gains its letter.

**Tech Stack:**
- Swift 6.4 in language mode 6, Swift Testing, Observation, SwiftUI, AppKit, WebKit.
- Monaco: the bundled copy the host page already loads (decorations, view zones, `createDiffEditor`).
- No Go change and no new dependency.

**Spec:** `docs/superpowers/specs/2026-10-15-3b-iii-changes-view-design.md`. Read it with this plan;
it is the authority. The rulings below are decisions made while planning. Task 8 writes each as a
dated amendment to the spec (`docs/agents/workflow.md`: *a design question reopened mid-build is a
dated amendment*).

## Global Constraints

Copied from the spec; every task's requirements include them.

- **⌘⇧G** toggles the Changes view on ⌘B's and ⌘⇧F's terms:
  - on Changes, it hides the column;
  - on another view, it switches to Changes;
  - with the column hidden, it shows the column on Changes.
- **One header per root:** `api · main · ↑2 ↓1`, `api · main · clean`, or a detached SHA, as
  `gitRootLine` reads. A header collapses its root. Collapsed roots are kept per pane, apart from
  Files' open folders (Decision 37), and saved with the layout.
- **Groups Staged, Changes, Untracked** under each root. An empty group is not drawn. A partly staged
  file appears twice.
- **Rows:** the status letter in its tone (added green, modified amber, deleted muted, **never red**)
  and the name. A rename reads `old → new`.
- **↑↓ move the highlight** across groups and roots. **Click or Return opens the diff tab.**
- **Live:** an edit, a `git add`, a commit or a branch switch from anywhere shows within about half a
  second, with no refresh control.
- **A root that is not a repository** reads `docs · not a git repository`, with no groups.
- **Diff tab title:** `User.php (Changes)` or `User.php (Staged)`. The same file's two diffs are two tabs.
- **The diff tab is read-only and inline,** drawn by Monaco's diff editor. Additions are §5 green
  (`#8be0c8`); deletions are a muted tone.
- **What each group diffs:**
  - Changes: the index against the working tree.
  - Staged: HEAD against the index.
  - Untracked: nothing against the working tree.
  - Deleted: the original against nothing on the right.
- **The preview-tab rule** (3b-ii): a single click or Return opens a preview diff tab, which the next
  one replaces. A double-click pins it.
- **⌘⏎ in a diff tab** opens the file as a file tab, at the line under the diff's cursor. It is not
  offered on a deleted file's diff, or on a Staged diff whose file is gone from the working tree.
- **Binary files, files over the cap and read errors** show 3a-i's banner, whole (Rule 8).
- **A diff tab stays live.** It re-reads when its root changes. If its file leaves its group, it reads
  *"No longer changed"* and stays open until closed.
- **Gutter marks:** a green bar beside added lines, an amber bar beside changed lines, and a small
  muted triangle between the lines where lines were deleted.
  - They compare **against the index**.
  - They update **from the buffer** as the operator or the agent types.
  - The index text is refetched on a wake.
  - Untracked files, files outside a repository, scratch tabs and read-only tabs get none.
- **The peek:**
  - Its header reads `2 of 5 changes · ↑ ↓ · Revert · ×`. Old lines are muted, new lines green.
  - ↑/↓ step to the previous or next hunk, and the editor scrolls to keep it in view.
  - **Revert** is a buffer edit: undoable with ⌘Z, unsaved until ⌘S, and **it asks nothing** (Rule 1).
    The peek then moves on, or closes when no change remains (Rule 6).
  - **Esc or ×** closes it and leaves the cursor (Rule 6). Typing closes it; the marks stay.
- **Tree letters:** a changed file's row shows its letter, in its tone, at the right edge. A file both
  staged and changed shows its working-tree letter. Folders are not tinted.
- **No write to git,** and nothing written to disk except by ⌘S. No side-by-side diff, no history,
  no marks against HEAD, no submodule descent.
- **Every action takes `pane`,** as the editor's do. `git_fold` and `git_unfold` are deleted.

| Action | Kind | Does | Replaces |
|---|---|---|---|
| `editor_tree(view: "changes")` | control | shows the column on Changes | — |
| `editor_changes_select(root, path, group, pin?)` | control | opens that diff tab (preview unless `pin`) | `git_select` |
| `editor_changes_step(delta)` | control | moves the highlight and opens its diff | `git_step` |
| `editor_changes_collapse(root)` / `editor_changes_expand(root)` | control | collapses or expands a root | — |
| `editor_open_file` | control | from a diff tab, opens the file at the cursor's line (⌘⏎) | — |
| `editor_peek(line)` | control | opens the peek on the hunk at `line` | — |
| `editor_peek_step(delta)` | control | moves the peek | — |
| `editor_peek_close` | control | closes it | — |
| `editor_replace_range` | control (existing) | Revert dispatches it with the hunk's range and old lines | — |
| `editor_refresh` | read (existing) | also re-reads git | `git_refresh` |

## Review Focus

The inputs and conditions most likely to bite. Each line has its test in the task named.

1. **A file both staged and changed, edited further while its Changes diff is open.** The open
   Changes tab re-reads, the Staged tab is a separate tab, and the tree shows the working-tree letter.
   *(Task 2 `aFileStagedAndChangedShowsItsWorkingTreeLetter`; Task 3
   `aWakeReReadsEveryOpenDiffTabUnderItsRoot`.)*
2. **The highlighted row disappears** after a commit or checkout from a terminal. The highlight moves
   to its neighbour, not the top, and to nothing only when its root is empty (Rule 6). *(Task 2
   `aVanishedHighlightMovesToTheRowAfterIt`, `…toTheLastWhenNothingFollows`, `…toNothingWhenTheRootEmptied`.)*
3. **A deletion at the very start or end of a file, and a file with no final newline.** Marks land
   on a real line, and Revert puts the exact text back. *(Task 6, the `editorHunks` table and
   `revertRestoresTheBaseText` for every row.)*
4. **The operator types while a diff or baseline read is in flight.** A late reply never writes into
   a tab that is gone, or a preview slot that now holds another file. *(Task 3
   `aPreviewReplacedWhileItsDiffLoadsNeverReceivesThatDiff`; Task 6
   `aBaselineLandingAfterItsTabClosedWritesNothing`.)*
5. **A layout saved by this build, read back by a build from before 3b-iii.** Today the whole file
   would be lost to the "could not be read" note, not just the column (ruling R1). *(Task 1
   `anUnknownColumnViewDecodesAsFiles`, `aLayoutWhoseDefaultColumnIsOnAnUnknownViewStillLoads`.)*

## Rulings made while planning (each becomes a dated spec amendment in Task 8)

- **R1. The older-build decode.** The spec asked to check first. The check: a pane's `editorColumn`
  is decoded with `try?`, so an unknown `view` only drops that pane's column. But
  `LayoutSnapshot.editorColumnDefault` is decoded with `try`, and `setEditorColumn` copies the view
  into it. So a build that does not know `changes` rejects the **whole layout file**.
  - The fix: `EditorColumnView` decodes an unknown value as `.files`.
  - It lands in **Task 1 (PR 1)**, a PR before anything writes `changes`. Every build from PR 1 on
    reads a 3b-iii layout.
  - A build from before PR 1 cannot be changed. Going back that far shows the note, as any unreadable
    layout does.
- **R2. Compare moves onto the pane's page.** 3b-i's Compare (disk ↔ buffer) is the other user of
  `MonacoDiffRenderer`. With one web view per pane, it shows through the same `showDiff`, and its Esc
  through the page's key capture. Its controls and identifiers are unchanged.
- **R3. `--probe-monaco` is deleted** with `MonacoDiffRenderer`, which is all it drives. It was
  3a-i Task 1's stop gate: *does Monaco's diff editor render offline in the bundle?* Every diff tab
  now answers that. (Overrule this and it is rebuilt on `MonacoEditorRenderer.showDiff` instead.)
- **R4. The status is an actor in `Git/`, not pane state.**
  - What reads it: `GitStatus` is handed to the window, the editor actions, `GitSource` and the
    palette.
  - What `read_pane` carries: the Changes column's highlight and collapsed roots, and each diff tab's
    facts.
  - Rows: the agent reads them with `git_status`, which is agent-facing. (`read_pane` is
    store-isolated and cannot await another actor.)
- **R5. `editor_refresh` gains `what`:** `all` (default), `files` or `git`. Each watcher wake then
  reads `git_status` once:
  - the file watcher dispatches `what: files`;
  - the git watcher reads the status once, then dispatches `what: git` to each editor pane.
  - `all`, the agent's, reads the status and then does both.
- **R6. The highlight's neighbour comes from step order, not the old list.** If the highlighted row
  is gone, it moves to the next row of its root in step order, else the last. That needs no `before`
  list, which the window's status cannot hand a pane action. It replaces `gitReselect`. Its 3a-i
  tests are ported with the outcome they pinned.
- **R7. Diff tabs are not saved with the layout.** 3b-i saves file tabs only. A migrated Git pane
  opens empty, with its column on Changes.
- **R8. A migrated Git pane keeps its id** (`git-1`), so the snap graph, focus and maximize still
  name it. Its title becomes `Editor`. There is no note: the pane is not lost, only renamed.
- **R9. A missing final newline is no hunk.** Lines are compared without the text's final newline,
  so `a\nb` and `a\nb\n` are equal. A mark on a line that looks unchanged would be noise.
- **R10. ⌘⏎ is Maximize Pane everywhere else.** In a focused editor pane whose active tab is a diff
  that may open its file, ⌘⏎ opens it. Otherwise it maximizes, as today. WakilKit decides
  (`editorCommandReturnOpensFile`).
- **R11. ⇧⌘G is Monaco's Find Previous.** The page hands it to the menu for ⌘⇧G. Find Previous stays
  on ⇧⏎ in the find bar.
- **R12. After a Revert the peek index is clamped.** The reverted hunk's successor takes its index,
  so the peek lands on the next hunk. If the reverted hunk was the last, it lands on the one before.
  It closes only when none remain.
- **R13. The page takes ↑, ↓ and Esc only while the peek is open, and Esc only while Compare is
  open.** Every other key is Monaco's.
- **R14. e2e.** The 3a-i git checks and `palette-new-git-parity.jsonl` are deleted with the kind in
  PR 3, with their `uncoverable.tsv` rows. The `3b-iii-changes-*` rewrites and the new checks are the
  **Cover** rung's (the e2e auditor), handed the spec's list in Task 8.

## File map

| File | PR | What |
|---|---|---|
| `app/Sources/WakilKit/Git/GitStatus.swift` | 1 | **Create.** `GitGroup`, `GitFileRow`, `GitRootState`, `GitActionError` and `gitRootState(root:result:)` move here. Adds the `GitStatus` actor. |
| `app/Sources/WakilKit/Git/GitSnapshot.swift` | 1, 3 | PR 1: the moved types leave. PR 3: deleted. |
| `app/Sources/WakilKit/Git/GitActions.swift` | 1, 3 | PR 1: reads through `GitStatus`, and `git_refresh` gains `read`. PR 3: deleted. |
| `app/Sources/WakilKit/Layout/Pane.swift` | 1, 2 | PR 1: `EditorColumnView` decodes leniently. PR 2: `.changes`, `EditorChangesRow`, and `EditorColumnState.changesClosed` / `changesHighlight`. |
| `app/Sources/WakilKit/App/WindowModel.swift` | 1, 2, 3, 6 | `gitStatus`, the `gitRoots` mirror, the watcher's terms, the wakes, ⌘⏎, and the git pane's code removed. |
| `app/Sources/WakilKit/App/AppWiring.swift`, `app/Sources/WakilApp/WindowSession.swift` | 1, 2, 3 | Build `GitStatus` and hand it on. |
| `app/Sources/WakilKit/Editor/EditorChanges.swift` | 2 | **Create.** Rows, step, highlight resolve, the tree's letter. |
| `app/Sources/WakilKit/Editor/EditorActions.swift` | 2, 3, 6, 7 | The new actions, `what`, diff tabs, baselines, peek. |
| `app/Sources/WakilKit/Editor/EditorPaneKind.swift` | 2, 3, 6, 7 | `read_pane` keys. |
| `app/Sources/WakilKit/Editor/EditorDiff.swift` | 3 | **Create.** `GitDiffState`, revisions, flights, title, ⌘⏎'s rule. |
| `app/Sources/WakilKit/Editor/EditorSnapshot.swift` | 3, 6, 7 | `.diff` subject, `diffState`, `baseline`, `peek`. |
| `app/Sources/WakilKit/Editor/EditorTabs.swift` | 3 | Titles, `editorTabParams`. |
| `app/Sources/WakilKit/Editor/EditorRenderer.swift` | 3, 6, 7 | `showDiff`, `setMarks`, `showPeek` and their steps. |
| `app/Sources/WakilKit/Editor/EditorHunks.swift` | 6, 7 | **Create.** `editorHunks`, the marks, the peek view and Revert. |
| `app/Sources/WakilKit/Layout/LayoutPersistence.swift`, `Layout/LayoutStore.swift` | 3 | `layoutMigratingGitPanes`. |
| `app/Sources/WakilKit/Command/{PaletteSources,PaletteEntry,CommandCatalog,PaletteSearch}.swift`, `Git/GitSource.swift` | 3 | Re-pointed at the window's status; git pane entries gone. |
| `app/Sources/WakilApp/EditorColumn.swift`, `EditorPane.swift`, `AppScene.swift`, `Canvas.swift`, `Landing.swift` | 2, 3, 6, 7 | Changes view, letters, ⌘⇧G, ⌘⏎, diff/compare/marks/peek wiring. |
| `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `monaco-host.html` | 3, 6, 7 | Diff editor in the page, key capture, marks, peek zone. |
| `app/Sources/WakilApp/{GitPane,MonacoDiffRenderer,MonacoProbe}.swift`, `Git/{GitPaneKind,PaneStore+Git,GitNavigation,DiffRenderer}.swift` | 3 | **Delete.** |
| `app/Tests/WakilKitTests/…` | all | Per task. |
| `e2e/checks/…`, `e2e/checks/uncoverable.tsv` | 3 | The git pane's checks and rows deleted (R14). |
| `docs/…` | 3, 8 | Architecture docs (PR 3); charter, spec amendments, acceptance runbook (PR 8 → PR 6). |

**PRs, stacked (`gh stack`), one unit each, as the spec lands them:**

| PR | Branch | Tasks |
|---|---|---|
| 1 | `yehia-khalil/3b-iii-1-git-status` | 1 |
| 2 | `yehia-khalil/3b-iii-2-changes-view` | 2 |
| 3 | `yehia-khalil/3b-iii-3-diff-tabs` | 3, 4, 5 |
| 4 | `yehia-khalil/3b-iii-4-gutter` | 6 |
| 5 | `yehia-khalil/3b-iii-5-peek` | 7 |
| 6 | `yehia-khalil/3b-iii-6-walk` | 8 |

Each PR ends with `make build`, `make test` and `make app-test` green. Commits carry no
`Co-Authored-By` line (`CONTRIBUTING.md`).

---
### Task 1: The window's git status; the watcher runs for editor panes; a lenient column view (PR 1)

**Files:**
- Create: `app/Sources/WakilKit/Git/GitStatus.swift`
- Modify: `app/Sources/WakilKit/Git/GitSnapshot.swift` (the three moved types leave)
- Modify: `app/Sources/WakilKit/Git/GitActions.swift` (moved code leaves; reads go through `GitStatus`)
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (`EditorColumnView.init(from:)`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`, `app/Sources/WakilKit/App/AppWiring.swift`,
  `app/Sources/WakilApp/WindowSession.swift`
- Test: `app/Tests/WakilKitTests/GitStatusTests.swift` (new),
  `app/Tests/WakilKitTests/WindowModelGitTests.swift`, `app/Tests/WakilKitTests/LayoutPersistenceTests.swift`,
  `app/Tests/WakilKitTests/InvalidationContractTests.swift`, every `registerGitActions(` call site in tests

**Interfaces:**
- Produces:
  - `public actor GitStatus`
    - `init(git: (any ToolCaller)?, roots: @escaping @Sendable () async -> [String])`
    - `nonisolated let git: (any ToolCaller)?`
    - `var roots: [GitRootState]` (read-only)
    - `func projectRoots() async -> [String]`
    - `func refresh(only: String? = nil) async`
    - `func reset()`
  - `registerGitActions(into:panes:layout:status:)`; `git_refresh` gains `read: Bool` (default true).
  - `WindowModel.gitRoots: [GitRootState]` (`public private(set)`), and the init parameter
    `gitStatus: GitStatus?` (no default).
  - `AppWiring.gitStatus: GitStatus`.

- [ ] **Step 1: Write the failing tests — the status**

`app/Tests/WakilKitTests/GitStatusTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Suite struct GitStatusTests {
    @Test func readsEveryRootInProjectOrderAndOneThatFailsHidesNoOther() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [("b.go", "changed", "M"), ("a.go", "staged", "A")])
        let status = GitStatus(git: git, roots: { ["/p/docs", "/p/api"] })
        await status.refresh()
        let roots = await status.roots
        #expect(roots.map(\.root) == ["/p/docs", "/p/api"])
        #expect(roots[0].error == "not a git repository" && roots[0].files.isEmpty)
        #expect(roots[1].files.map(\.path) == ["a.go", "b.go"], "staged before changed")
        #expect(!roots.contains { $0.loading })
    }

    @Test func onlyReadsTheNamedRootAndKeepsTheOthers() async {
        let git = FakeGit()
        for r in ["/p/api", "/p/web"] { await git.set(status: r, files: [("x", "changed", "M")]) }
        let status = GitStatus(git: git, roots: { ["/p/api", "/p/web"] })
        await status.refresh()
        await git.set(status: "/p/web", files: [])
        await status.refresh(only: "/p/api")
        #expect(await git.calls.filter { $0.hasPrefix("git_status") }.count == 3)
        #expect(await status.roots[1].files.map(\.path) == ["x"], "/p/web was not read again")
    }

    @Test func aRootOutsideTheProjectReadsNothing() async {
        let git = FakeGit()
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        await status.refresh(only: "/elsewhere")
        #expect(await git.calls.isEmpty)
    }

    // 3a-i's rule, kept: a slow old reply lands after a newer read and is dropped whole.
    @Test func aReadSupersededByANewerOneLandsNothing() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [("old", "changed", "M")])
        await git.setSlowStatus(true)
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        let first = Task { await status.refresh() }
        while await git.statusCount < 1 { await Task.yield() }
        await git.set(status: "/p/api", files: [("new", "changed", "M")])
        let second = Task { await status.refresh() }
        while await git.statusCount < 2 { await Task.yield() }
        await git.releaseStatus(1)
        await second.value
        await git.releaseStatus(0)
        await first.value
        #expect(await status.roots[0].files.map(\.path) == ["new"])
        #expect(await status.roots[0].loading == false)
    }

    @Test func noClientSaysSoUnderEachRoot() async {
        let status = GitStatus(git: nil, roots: { ["/p/api"] })
        await status.refresh()
        #expect(await status.roots[0].error?.contains("git") == true)
    }

    @Test func resetForgetsEveryRoot() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [])
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        await status.refresh()
        await status.reset()
        #expect(await status.roots.isEmpty)
    }
}
```

- [ ] **Step 2: Write the failing tests — the lenient view (R1)**

In `LayoutPersistenceTests.swift`:

```swift
@Test func anUnknownColumnViewDecodesAsFiles() throws {
    let json = #"{"shown":true,"view":"timeline","width":240,"open":[]}"#
    let c = try JSONDecoder().decode(EditorColumnState.self, from: Data(json.utf8))
    #expect(c.view == .files && c.shown)
}

@Test func aLayoutWhoseDefaultColumnIsOnAnUnknownViewStillLoads() throws {
    let json = #"{"panes":[],"graph":{"edges":[]},"editorColumnDefault":{"shown":true,"view":"timeline","width":300,"open":[]}}"#
    let s = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(json.utf8))
    #expect(s.editorColumnDefault?.view == .files && s.editorColumnDefault?.width == 300)
}
```

Before running: check `SnapGraph`'s encoded shape in an existing test in this file. If it is not
`{"edges":[]}`, encode `LayoutSnapshot(panes: [], graph: SnapGraph())` and splice the
`editorColumnDefault` object into that text instead.

- [ ] **Step 3: Write the failing tests — the window**

In `WindowModelGitTests.swift`:
- `gitWindow` builds one `GitStatus(git: git, roots: { [weak model] in await model?.gitRootPaths ?? [] })`.
  Build it before the model with a box, as below. Pass it as `gitStatus:` to `WindowModel` and as
  `status:` to `registerGitActions`.
- Because `roots` must reach the model, give the status a closure that reads a `@MainActor` box set
  after the model is made:

```swift
@MainActor final class RootsBox { weak var model: WindowModel? }
// in gitWindow:
let box = RootsBox()
let status = GitStatus(git: git, roots: { await box.model?.gitRootPaths ?? [] })
let model = WindowModel(…, rootWatcher: watcher, editorRootWatcher: nil, fileLists: nil,
                        gitStatus: status, paletteClients: PaletteClients())
box.model = model
await registerGitActions(into: registry, panes: panes, layout: layout, status: status)
```

Add these tests:

```swift
    @Test func anEditorPaneAloneStartsTheWatcherAndTheStatusIsReadFirst() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds"])
        #expect(model.gitRoots.map(\.root) == ["/p/api", "/p/portal"])
        #expect(await git.statusCount == 2, "one read per root, before any wake")
    }

    @Test func oneReadPerRootPerWakeWhateverTheNumberOfPanes() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        await model.openPane(kind: "git")
        await model.openPane(kind: "editor")
        let before = await git.statusCount
        await watcher.fire("/p/api")
        #expect(await git.statusCount == before + 1)
        for pane in await openGitPanes(model) {
            #expect(model.git(pane)?.roots.first?.files.map(\.path) == ["a.txt"], "every git pane shows the one read")
        }
    }

    @Test func nothingIsReadWithNoPaneThatShowsGit() async throws {
        let (model, watcher, git, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "api")
        #expect(await watcher.events.isEmpty)
        #expect(await git.statusCount == 0)
    }

    @Test func anOrgSwitchEmptiesTheMirror() async throws {
        let (model, _, _, _) = await gitWindow()
        await model.refreshContext()
        await model.openPane(kind: "editor")
        await model.invalidateForOrgChange()
        #expect(model.gitRoots.isEmpty)
    }
```

Run: `cd app && swift test --filter 'GitStatusTests|WindowModelGitTests|LayoutPersistenceTests'`

Expected: build failure — `GitStatus`, `gitStatus:` and `gitRoots` do not exist.

- [ ] **Step 4: Create `Git/GitStatus.swift`**

Move these here verbatim, deleting them where they were:
- `GitGroup`, `GitFileRow` and `GitRootState` from `GitSnapshot.swift`;
- `GitActionError`, the private `string(_:_:)` and `gitGroupRank(_:)`, `gitRootState(root:result:)` and
  `gitPendingRoot(_:)` from `GitActions.swift`.

`gitPendingRoot` and `gitRootState` drop `private`/stay internal. Then add:

```swift
/// The window's git status (3b-iii): one `git_status` per root, read once per watcher wake and
/// shared by everything that shows git — the Changes view, the tree's letters, the gutter's
/// baselines, ⌘P's changed files and the vocabulary. Nothing else reads `git_status` for a pane.
///
/// **Each root is read on its own** and a root that fails carries its own `error`, whole (Rule 8);
/// it never hides a sibling. **A read a newer one superseded lands nothing** — neither its list nor
/// the end of its `loading` — so a slow old reply cannot show a stale list (3a-i's `GitFlights`
/// generations, moved here). A read cut short by cancellation writes no error; its root keeps what
/// it showed.
public actor GitStatus {
    /// wakil-git: these reads, and the diffs and index texts the editor fetches through it.
    public nonisolated let git: (any ToolCaller)?
    private let roots_: @Sendable () async -> [String]
    /// Every project root in project order, as last read. Empty before the first read and after `reset`.
    public private(set) var roots: [GitRootState] = []
    private var latest: [String: Int] = [:]
    private var generation = 0

    public init(git: (any ToolCaller)?, roots: @escaping @Sendable () async -> [String]) {
        self.git = git
        self.roots_ = roots
    }

    /// The active project's roots, asked live (the window's, else `wakil-ctx`'s).
    public func projectRoots() async -> [String] { await roots_() }

    /// Reads `only`, or every root. Roots the project no longer has are dropped, and roots it gained
    /// are listed loading; a root outside the project reads nothing.
    public func refresh(only: String? = nil) async {
        let all = await roots_()
        let targets = only.map { all.contains($0) ? [$0] : [] } ?? all
        let known = Dictionary(roots.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        roots = all.map { r in
            var state = known[r] ?? gitPendingRoot(r)
            if targets.contains(r) { state.loading = true }
            return state
        }
        generation += 1
        let mine = generation
        for r in targets { latest[r] = mine }
        let read = await gitReadStatus(git, roots: targets)
        roots = roots.map { state in
            guard let outcome = read[state.root], latest[state.root] == mine else { return state }
            guard let fresh = outcome else {
                var kept = state
                kept.loading = false
                return kept
            }
            return fresh
        }
    }

    /// Forgets every root (an org switch, or no pane left that shows git).
    public func reset() {
        roots = []
        latest = [:]
    }
}

/// Each root's `git_status`, in parallel: the decoded state, or nil when the read was cancelled.
private func gitReadStatus(_ git: (any ToolCaller)?, roots: [String]) async -> [String: GitRootState?] {
    await withTaskGroup(of: (String, GitRootState?).self) { group in
        for r in roots {
            group.addTask {
                guard let git else {
                    return (r, gitRootState(root: r, result: .failure(
                        StandardActionError.missingClient(action: "git_status", role: "git"))))
                }
                let result: Result<JSONValue, Error>
                do {
                    result = .success(try await git.callTool(
                        name: "git_status", arguments: .object(["root": .string(r)]),
                        timeout: MCPClient.readReplyTimeout))
                } catch {
                    result = .failure(error)
                }
                if Task.isCancelled { return (r, nil) }
                if case .failure(let error) = result, error is CancellationError { return (r, nil) }
                return (r, gitRootState(root: r, result: result))
            }
        }
        var states: [String: GitRootState?] = [:]
        for await (r, state) in group { states[r] = state }
        return states
    }
}
```

- [ ] **Step 5: `registerGitActions` reads through the status**

In `GitActions.swift`:
- The signature becomes
  `registerGitActions(into registry: ActionRegistry, panes: PaneStore, layout: LayoutStore?, status: GitStatus)`.
  The `git` parameter becomes `let git = status.git` at the top. `roots()` becomes
  `status.projectRoots()`.
- `GitFlights` loses `reads`, `generation`, `beginRead` and `isLatestRead`; the status owns them now.
- `refresh(_:only:_:)` is replaced by `adopt`:

```swift
    /// Takes the window's status as it now is into the pane, and moves the selection per Rule 6.
    @Sendable func adopt(_ pane: String, _ git: any ToolCaller) async {
        let fresh = await status.roots
        let reload: Task<Void, Never>? = await panes.updateGit(paneId: pane, create: true) { s in
            let before = s.roots
            s.roots = fresh
            guard fresh != before, let selection = s.selection else { return nil }
            switch gitReselect(selection, before: before, after: s.roots) {
            case .keep(let next), .moved(let next):
                s.selection = next
                s.diff?.loading = true
                return diffFlight(pane, next, status: gitFileRow(next, in: s.roots)?.status, git)
            case .unfold(let root):
                s.selection = nil
                s.folded = false
                s.diff = nil
                s.inView = root
                return nil
            }
        }
        await reload?.value
    }
```

- `git_refresh` gains `read`, documented and used:

```swift
        description: "Re-read git status for the git pane: one root (root, an absolute path that "
            + "is one of the active project's roots) or, naming none, every root. With read false, "
            + "takes the window's status as it already is (the window read it on a file event). "
            + "Each root is read on its own; one that fails shows its error and hides nothing else. "
            + "The selection stays on its file, follows it to another group, or moves to the row "
            + "that took its place; its diff is read again. Returns the pane's snapshot.",
        …
        schema: gitSchema(["root": .object(["type": .string("string")]),
                           "read": .object(["type": .string("boolean")])], required: []),
        handler: { params in
            let pane = try await gitPane(params, action: "git_refresh", layout: layout)
            let git = try requireGit("git_refresh")
            let only = optionalString(params, "root")
            if let only {
                let all = await status.projectRoots()
                guard all.contains(only) else {
                    throw GitActionError.notAProjectRoot(action: "git_refresh", root: only, roots: all)
                }
            }
            if case .object(let o) = params, o["read"] == .bool(false) {} else { await status.refresh(only: only) }
            await adopt(pane, git)
            return await snapshot(pane)
        }))
```

- Every test call site: replace `git: g, roots: r` with `status: GitStatus(git: g, roots: r)`.
  Find them with `grep -rn 'registerGitActions(' app/Tests`.
  - A test that passed `git: nil` keeps its `missingClient` expectation: `requireGit` still throws.
  - In `GitActionsTests`, a test that counted reads against a refresh's `loading` or `generation` now
    pins the same rule through `GitStatusTests`. Delete only the assertion that reached into the pane
    mid-read, and say so in the test's comment.

- [ ] **Step 6: `EditorColumnView` decodes leniently (R1)**

In `Layout/Pane.swift`:

```swift
public enum EditorColumnView: String, Sendable, Equatable, Codable {
    case files, search

    /// **An unknown view decodes as `.files`** (3b-iii, R1): a layout written by a later build keeps
    /// its column, and `LayoutSnapshot.editorColumnDefault` — decoded with `try` — does not take the
    /// whole file down with it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EditorColumnView(rawValue: raw) ?? .files
    }
}
```

- [ ] **Step 7: The window owns the status and watches for editor panes too**

In `WindowModel.swift`:
- Beside `gitWatcher`:

```swift
    /// The window's git status (3b-iii): one `git_status` per root per wake, shared by every pane that
    /// shows git. No default, for `rootWatcher`'s reason (`wakil-never-wired-parameters`): production
    /// passes `wiring.gitStatus`, the one the actions were registered with; a test that shows no git
    /// says `nil` out loud.
    private let gitStatus: GitStatus?
    /// The status as last mirrored, for the views: the Changes view, the tree's letters, ⌘P.
    public private(set) var gitRoots: [GitRootState] = []
```

- Both initialisers gain `gitStatus: GitStatus?` after `fileLists:` (no default on the public one,
  `nil` on the test-only builder) and assign it.
- In `syncGitWatcher`, the panes that want the watch, and what a start reads:

```swift
        let showsGit = layoutSnapshot.panes.contains {
            PaneKinds.is($0.kind, GitPaneKind.self) || PaneKinds.is($0.kind, EditorPaneKind.self)
        }
        let wanted = showsGit ? roots : []
        …
        case .started:
            // **A watch that starts reads first** (fix round 1, I1), now once for the window.
            await gitStatus?.refresh()
            await refreshGitPanes(root: nil)
        case .stopped:
            await gitStatus?.reset()
            gitRoots = []
```

- `gitRootChanged` reads once, then hands the result to the panes without a second read:

```swift
    private func gitRootChanged(_ root: String) async {
        guard gitRootPaths.contains(root) else { return }   // a wake from a project just left
        gitRoots = gitRoots.map { var r = $0; if r.root == root { r.loading = true }; return r }
        await gitStatus?.refresh(only: root)
        await refreshGitPanes(root: root)
    }
```

- In `refreshGitPanes` and `refreshUnreadGitPanes`: when `gitStatus != nil`, add
  `params["read"] = .bool(false)`. `refreshUnreadGitPanes` builds its params as a `var` dictionary to
  do it.
- In `refreshPanes()`, after the loop over the layout's panes: `gitRoots = await gitStatus?.roots ?? []`.
- In `invalidateForOrgChange()`, before its trailing `syncGitWatcher()`:
  `await gitStatus?.reset(); gitRoots = []`.
- `InvalidationContractTests.swift`:
  - `gitStatus` joins the injected list beside `gitWatcher`, with the comment: *"3b-iii PR 1: one for
    the window's life (the wiring's), its CONTENTS the outgoing org's status. `invalidateForOrgChange`
    resets it (WindowModelGitTests.anOrgSwitchEmptiesTheMirror)."*
  - `gitRoots` joins the org-derived list, reset in the same place.

- [ ] **Step 8: The wiring builds it**

In `AppWiring.swift`:
- Add `public let gitStatus: GitStatus`, documented as *"The window's git status (3b-iii). One per
  assembly; the window, the actions and `GitSource` share it."*
- Build it after `gitRoots`: `let gitStatus = GitStatus(git: gitClient, roots: { await gitRoots.current() })`.
- Pass `status: gitStatus` to `registerGitActions`, and assign the property in the initialiser
  wherever `rootWatcher` is.

In `WindowSession.swift`, pass `gitStatus: wiring.gitStatus,` after `fileLists:`, with the comment
*"3b-iii. The status the actions read; no default, for `rootWatcher`'s reason."* In
`AppWiringTests`, add `theStatusIsTheOneTheActionsRead`: build the wiring and assert
`wiring.gitStatus.git` is the wiring's git client (`===` on the client object, as
`theWatcherIsActuallyPassedIn` does).

Every other `WindowModel(` call in tests gains `gitStatus: nil` (find them with
`grep -rln 'editorRootWatcher:' app/Tests`).

- [ ] **Step 9: Run the tests**

Run: `cd app && swift test --filter 'GitStatusTests|WindowModelGitTests|LayoutPersistenceTests|GitActionsTests|InvalidationContractTests|AppWiringTests'`
Expected: PASS.

Then the suites: `make build && make test && make app-test`. Expected: green.

- [ ] **Step 10: Commit and open PR 1**

```bash
git switch -c yehia-khalil/3b-iii-1-git-status
git add app/Sources app/Tests
git commit -m "3b-iii PR 1: one git status for the window; the watcher runs for editor panes; an unknown column view decodes as files"
gh stack submit   # or: gh pr create --base main, per the gh-stack skill
```

The PR body says that the Git pane reads the shared status and nothing changes on screen.

---
### Task 2: The Changes view, its actions, the tree's letters, ⌘⇧G (PR 2)

**Files:**
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (`.changes`, `EditorChangesRow`, the column's two fields)
- Create: `app/Sources/WakilKit/Editor/EditorChanges.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift`, `app/Sources/WakilKit/Editor/EditorPaneKind.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`, `app/Sources/WakilKit/App/AppWiring.swift`
- Modify: `app/Sources/WakilApp/EditorColumn.swift`, `app/Sources/WakilApp/EditorPane.swift`,
  `app/Sources/WakilApp/Canvas.swift`, `app/Sources/WakilApp/AppScene.swift`,
  `app/Sources/WakilApp/monaco-host.html`
- Modify: `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt` (add `Editor -> Git`)
- Test: `app/Tests/WakilKitTests/EditorChangesTests.swift` (new),
  `app/Tests/WakilKitTests/EditorChangesActionsTests.swift` (new),
  `app/Tests/WakilKitTests/EditorTestSupport.swift`, `app/Tests/WakilKitTests/WindowModelEditorTests.swift`,
  `app/Tests/WakilKitTests/LayoutPersistenceTests.swift`

**Interfaces:**
- Consumes (Task 1): `GitStatus` (`roots`, `refresh(only:)`, `projectRoots()`); `GitGroup`,
  `GitFileRow`, `GitRootState`, `GitActionError`.
- Produces:
  - `EditorColumnView.changes`.
  - `public struct EditorChangesRow: Sendable, Equatable, Hashable, Codable { root: String; path: String; group: String }`,
    in `Layout/` (`group` is a `GitGroup` raw value).
  - `EditorColumnState.changesClosed: Set<String>` and `EditorColumnState.changesHighlight: EditorChangesRow?`.
  - In `EditorChanges.swift`:
    - `editorChangesRows(_ roots: [GitRootState], closed: Set<String>) -> [EditorChangesRow]`
    - `editorChangesStep(_ roots:, closed:, from: EditorChangesRow?, by: Int) -> EditorChangesRow?`
    - `editorChangesResolve(_ highlight: EditorChangesRow?, roots:) -> EditorChangesRow?`
    - `editorChangesFile(_ row: EditorChangesRow, in roots:) -> GitFileRow?`
    - `editorTreeStatus(root: String, relative: String, roots:) -> String?`
  - `registerEditorActions(…, fileLists:, gitStatus: GitStatus?, roots:)`.
  - The actions `editor_changes_select`, `editor_changes_step`, `editor_changes_collapse` and
    `editor_changes_expand`.
  - `editor_refresh`'s `what`, and `editor_tree`'s `view: "changes"`.
  - A private `refreshGit(_ pane: String, root: String?) async` inside `registerEditorActions`, which
    Tasks 3 and 6 extend.
  - `EditorFixture.git: FakeGit` and `EditorFixture.status: GitStatus`.

- [ ] **Step 1: Write the failing pure tests**

`app/Tests/WakilKitTests/EditorChangesTests.swift`. The step and reselect cases are ported from
`GitNavigationTests` with the outcomes they pinned (R6):

```swift
import Testing
@testable import WakilKit

private func root(_ r: String, _ files: [(String, GitGroup, String)], loading: Bool = false) -> GitRootState {
    GitRootState(root: r, name: (r as NSString).lastPathComponent, branch: "main", detached: "", ahead: 0,
                 behind: 0, files: files.map { GitFileRow(path: $0.0, origPath: nil, group: $0.1, status: $0.2) },
                 error: nil, loading: loading)
}
private func row(_ r: String, _ p: String, _ g: GitGroup) -> EditorChangesRow {
    EditorChangesRow(root: r, path: p, group: g.rawValue)
}

private let two = [
    root("/p/api", [("z.go", .changed, "M"), ("a.go", .staged, "A"), ("n", .untracked, "?"), ("b.go", .changed, "M")]),
    root("/p/web", [("i.ts", .changed, "M")]),
]

@Suite struct EditorChangesTests {
    @Test func rowsAreRootsInOrderThenStagedChangesUntrackedThenPath() {
        #expect(editorChangesRows(two, closed: []) == [
            row("/p/api", "a.go", .staged), row("/p/api", "b.go", .changed), row("/p/api", "z.go", .changed),
            row("/p/api", "n", .untracked), row("/p/web", "i.ts", .changed)])
    }

    @Test func aCollapsedRootsRowsAreLeftOut() {
        #expect(editorChangesRows(two, closed: ["/p/api"]) == [row("/p/web", "i.ts", .changed)])
    }

    @Test func aStepCrossesGroupsAndRootsAndStopsAtEitherEnd() {
        let from = row("/p/api", "n", .untracked)
        #expect(editorChangesStep(two, closed: [], from: from, by: 1) == row("/p/web", "i.ts", .changed))
        #expect(editorChangesStep(two, closed: [], from: from, by: 9) == row("/p/web", "i.ts", .changed))
        #expect(editorChangesStep(two, closed: [], from: from, by: -9) == row("/p/api", "a.go", .staged))
    }

    @Test func aStepWithNothingHighlightedStartsAtTheFirstRow() {
        #expect(editorChangesStep(two, closed: [], from: nil, by: 1) == row("/p/api", "a.go", .staged))
        #expect(editorChangesStep([], closed: [], from: nil, by: 1) == nil)
    }

    @Test func aStepSkipsACollapsedRoot() {
        let roots = two + [root("/p/zed", [("q", .changed, "M")])]
        #expect(editorChangesStep(roots, closed: ["/p/web"], from: row("/p/api", "n", .untracked), by: 1)
            == row("/p/zed", "q", .changed))
    }

    @Test func aHighlightStillListedStays() {
        let h = row("/p/api", "b.go", .changed)
        #expect(editorChangesResolve(h, roots: two) == h)
    }

    // 3a-i: `git add` moved the file from Changes to Staged; the highlight follows it.
    @Test func aHighlightWhoseFileMovedGroupFollowsIt() {
        let after = [root("/p/api", [("b.go", .staged, "M")])]
        #expect(editorChangesResolve(row("/p/api", "b.go", .changed), roots: after) == row("/p/api", "b.go", .staged))
    }

    // Rule 6: a vanished row hands the highlight to its neighbour, not to the top (R6).
    @Test func aVanishedHighlightMovesToTheRowAfterIt() {
        let after = [root("/p/api", [("a.go", .staged, "A"), ("z.go", .changed, "M"), ("n", .untracked, "?")])]
        #expect(editorChangesResolve(row("/p/api", "b.go", .changed), roots: after) == row("/p/api", "z.go", .changed))
    }

    @Test func aVanishedHighlightMovesToTheLastWhenNothingFollows() {
        let after = [root("/p/api", [("a.go", .staged, "A"), ("b.go", .changed, "M")])]
        #expect(editorChangesResolve(row("/p/api", "n", .untracked), roots: after) == row("/p/api", "b.go", .changed))
    }

    @Test func aVanishedHighlightMovesToNothingWhenTheRootEmptied() {
        let after = [root("/p/api", []), root("/p/web", [("i.ts", .changed, "M")])]
        #expect(editorChangesResolve(row("/p/api", "n", .untracked), roots: after) == nil)
    }

    @Test func aRootNotReadYetKeepsTheHighlight() {
        let h = row("/p/api", "n", .untracked)
        #expect(editorChangesResolve(h, roots: [root("/p/api", [], loading: true)]) == h)
        #expect(editorChangesResolve(h, roots: []) == h)
    }

    @Test func aFileStagedAndChangedShowsItsWorkingTreeLetter() {
        let r = [root("/p/api", [("x.go", .staged, "A"), ("x.go", .changed, "M"), ("n", .untracked, "?")])]
        #expect(editorTreeStatus(root: "/p/api", relative: "x.go", roots: r) == "M")
        #expect(editorTreeStatus(root: "/p/api", relative: "n", roots: r) == "?")
        #expect(editorTreeStatus(root: "/p/api", relative: "y.go", roots: r) == nil)
        #expect(editorTreeStatus(root: "/p/web", relative: "x.go", roots: r) == nil)
    }

    @Test func aFileOnlyStagedShowsItsStagedLetter() {
        let r = [root("/p/api", [("x.go", .staged, "D")])]
        #expect(editorTreeStatus(root: "/p/api", relative: "x.go", roots: r) == "D")
    }
}
```

Run: `cd app && swift test --filter EditorChangesTests`. Expected: build failure (no
`EditorChangesRow`).

- [ ] **Step 2: The layout's types**

In `Layout/Pane.swift`:

```swift
public enum EditorColumnView: String, Sendable, Equatable, Codable {
    case files, search, changes
    // init(from:) as Task 1 left it
}

/// One row of the editor's Changes view (3b-iii): a file in one group of one root. `group` is a
/// `GitGroup` raw value, spelt out because `Layout/` may not use `Git/`.
public struct EditorChangesRow: Sendable, Equatable, Hashable, Codable {
    public var root: String
    public var path: String
    public var group: String
    public init(root: String, path: String, group: String) {
        self.root = root
        self.path = path
        self.group = group
    }
}
```

`EditorColumnState` gains two fields, an init with defaults, and a tolerant decoder:

```swift
public struct EditorColumnState: Sendable, Equatable, Codable {
    public var shown: Bool
    public var view: EditorColumnView
    public var width: Double
    public var open: [String]
    /// Roots collapsed in the Changes view (3b-iii): per pane, apart from `open` (Decision 37).
    public var changesClosed: Set<String>
    /// The Changes view's highlighted row; nil before one is chosen.
    public var changesHighlight: EditorChangesRow?
    public static let initial = EditorColumnState(shown: false, view: .files, width: 240, open: [])
    public init(shown: Bool, view: EditorColumnView, width: Double, open: [String],
                changesClosed: Set<String> = [], changesHighlight: EditorChangesRow? = nil) {
        self.shown = shown
        self.view = view
        self.width = width
        self.open = open
        self.changesClosed = changesClosed
        self.changesHighlight = changesHighlight
    }

    private enum CodingKeys: String, CodingKey { case shown, view, width, open, changesClosed, changesHighlight }

    /// A column saved before 3b-iii has neither Changes field: they decode as empty, not as a failure.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shown = try c.decode(Bool.self, forKey: .shown)
        view = try c.decode(EditorColumnView.self, forKey: .view)
        width = try c.decode(Double.self, forKey: .width)
        open = try c.decode([String].self, forKey: .open)
        changesClosed = (try? c.decodeIfPresent(Set<String>.self, forKey: .changesClosed)) ?? []
        changesHighlight = (try? c.decodeIfPresent(EditorChangesRow.self, forKey: .changesHighlight)) ?? nil
    }
}
```

`LayoutStore.setEditorColumn`'s default copy keeps passing four arguments, so the default never
carries one pane's highlight or collapsed roots.

In `LayoutPersistenceTests.swift`:

```swift
@Test func aColumnSavedBefore3biiiDecodesWithNoChangesState() throws {
    let json = #"{"shown":true,"view":"search","width":240,"open":["/p/api"]}"#
    let c = try JSONDecoder().decode(EditorColumnState.self, from: Data(json.utf8))
    #expect(c.changesClosed.isEmpty && c.changesHighlight == nil && c.open == ["/p/api"])
}

@Test func theChangesStateRoundTrips() throws {
    let c = EditorColumnState(shown: true, view: .changes, width: 260, open: [], changesClosed: ["/p/web"],
                              changesHighlight: EditorChangesRow(root: "/p/api", path: "a.go", group: "staged"))
    #expect(try JSONDecoder().decode(EditorColumnState.self, from: JSONEncoder().encode(c)) == c)
}
```

- [ ] **Step 3: `Editor/EditorChanges.swift`**

```swift
import Foundation

// The Changes view's rows and the choices behind them (3b-iii), pure, because WakilApp has no test
// target. The status is the window's (`GitStatus`); the highlight and collapsed roots are the pane's.

private func editorChangesRank(_ group: String) -> Int {
    switch GitGroup(rawValue: group) {
    case .staged?: 0
    case .changed?: 1
    case .untracked?, nil: 2
    }
}

/// Step order within one root: staged, changes, untracked, then path in byte order.
private func editorChangesPrecedes(_ a: EditorChangesRow, _ b: EditorChangesRow) -> Bool {
    let ra = editorChangesRank(a.group), rb = editorChangesRank(b.group)
    if ra != rb { return ra < rb }
    return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
}

private func editorChangesRows(of r: GitRootState) -> [EditorChangesRow] {
    r.files.map { EditorChangesRow(root: r.root, path: $0.path, group: $0.group.rawValue) }
        .sorted(by: editorChangesPrecedes)
}

/// Every row the view draws, in step order: roots in project order, a collapsed root's rows left
/// out, then staged, changes, untracked, then path.
public func editorChangesRows(_ roots: [GitRootState], closed: Set<String>) -> [EditorChangesRow] {
    roots.filter { !closed.contains($0.root) }.flatMap(editorChangesRows(of:))
}

/// The row `delta` away from `from` among the drawn rows, clamped at both ends; the first row when
/// `from` is nil or not drawn; nil when nothing is drawn.
public func editorChangesStep(_ roots: [GitRootState], closed: Set<String>, from: EditorChangesRow?,
                              by delta: Int) -> EditorChangesRow? {
    let rows = editorChangesRows(roots, closed: closed)
    guard !rows.isEmpty else { return nil }
    guard let from, let i = rows.firstIndex(of: from) else { return rows.first }
    return rows[min(max(i + delta, 0), rows.count - 1)]
}

/// Where the highlight is after a refresh (Rule 6, R6).
/// - Still listed: it stays.
/// - Its file is still in its root but in another group (`git add`): it follows the file, to the
///   first such row in step order.
/// - Its file is gone: it moves to the root's next row in step order, else the last.
/// - Its root has nothing left: nil.
/// - Its root not read yet (absent, or loading with no files): kept, since nothing says it went.
public func editorChangesResolve(_ highlight: EditorChangesRow?, roots: [GitRootState]) -> EditorChangesRow? {
    guard let h = highlight else { return nil }
    guard let r = roots.first(where: { $0.root == h.root }), !(r.loading && r.files.isEmpty) else { return h }
    let rows = editorChangesRows(of: r)
    if rows.contains(h) { return h }
    if let moved = rows.first(where: { $0.path == h.path }) { return moved }
    guard !rows.isEmpty else { return nil }
    return rows.first(where: { editorChangesPrecedes(h, $0) }) ?? rows.last
}

/// The status row a Changes row names, or nil when it is not in that group now.
public func editorChangesFile(_ row: EditorChangesRow, in roots: [GitRootState]) -> GitFileRow? {
    roots.first { $0.root == row.root }?.files.first { $0.path == row.path && $0.group.rawValue == row.group }
}

/// The letter a Files tree row shows at its right edge, or nil for an unchanged file. A file both
/// staged and changed shows its working-tree letter: Changes, then Untracked, then Staged.
public func editorTreeStatus(root: String, relative: String, roots: [GitRootState]) -> String? {
    guard let r = roots.first(where: { $0.root == root }) else { return nil }
    let rows = r.files.filter { $0.path == relative }
    for group in [GitGroup.changed, .untracked, .staged] {
        if let f = rows.first(where: { $0.group == group }) { return f.status }
    }
    return nil
}
```

Add `Editor -> Git` to `Fixtures/layering-allowed.txt`, in sorted position.

Run: `cd app && swift test --filter 'EditorChangesTests|LayoutPersistenceTests'`. Expected: PASS.

- [ ] **Step 4: Write the failing action tests**

In `EditorTestSupport.swift`:
- `EditorFixture` gains `let git: FakeGit` and `let status: GitStatus`.
- `editorFixture(roots:)` builds them before registering:

```swift
    let git = FakeGit()
    let status = GitStatus(git: git, roots: { await files.fixtureRoots() ?? roots })
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
                                gitStatus: status, roots: { await files.fixtureRoots() ?? roots })
    return EditorFixture(registry: registry, panes: panes, layout: layout, files: files, pane: pane,
                         git: git, status: status)
```

Every other `registerEditorActions(` call in tests gains `gitStatus: nil,` (6 sites).

`app/Tests/WakilKitTests/EditorChangesActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// /p/api: a.go staged, b.go changed, n untracked; /p/web: i.ts changed. The status read once.
func changesFixture() async throws -> EditorFixture {
    let f = try await editorFixture()
    await f.git.set(status: "/p/api", files: [("a.go", "staged", "A"), ("b.go", "changed", "M"), ("n", "untracked", "?")])
    await f.git.set(status: "/p/web", files: [("i.ts", "changed", "M")])
    await f.status.refresh()
    return f
}

private func highlight(_ f: EditorFixture) async -> EditorChangesRow? { await f.snapshot().column?.changesHighlight }

@Suite struct EditorChangesActionsTests {
    @Test func theTreeShowsTheChangesView() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_tree", ["view": .string("changes")])
        let c = try #require(await f.snapshot().column)
        #expect(c.shown && c.view == .changes)
    }

    @Test func selectHighlightsTheRow() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("b.go"),
                                                       "group": .string("changed")])
        #expect(await highlight(f) == EditorChangesRow(root: "/p/api", path: "b.go", group: "changed"))
    }

    @Test func selectRefusesARootOutsideTheProjectNamingTheRoots() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.notAProjectRoot(action: "editor_changes_select", root: "/x",
                                                             roots: ["/p/api", "/p/web"])) {
            try await f.dispatch("editor_changes_select", ["root": .string("/x"), "path": .string("a"),
                                                           "group": .string("changed")])
        }
    }

    @Test func selectRefusesAnUnknownGroup() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.unknownGroup(action: "editor_changes_select", group: "stash")) {
            try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("a"),
                                                           "group": .string("stash")])
        }
    }

    @Test func stepMovesAcrossGroupsAndRootsAndSkipsACollapsedRoot() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        #expect(await highlight(f)?.path == "a.go")
        try await f.dispatch("editor_changes_step", ["delta": .integer(3)])
        #expect(await highlight(f) == EditorChangesRow(root: "/p/web", path: "i.ts", group: "changed"))
        try await f.dispatch("editor_changes_collapse", ["root": .string("/p/web")])
        #expect(await f.snapshot().column?.changesClosed == ["/p/web"])
        try await f.dispatch("editor_changes_step", ["delta": .integer(-1)])
        // The highlight sat in the root just collapsed, so it is not drawn: a step starts again at the
        // first drawn row, as one with nothing highlighted does (`editorChangesStep`).
        #expect(await highlight(f)?.path == "a.go")
        try await f.dispatch("editor_changes_expand", ["root": .string("/p/web")])
        #expect(await f.snapshot().column?.changesClosed == [])
    }

    @Test func collapseRefusesARootOutsideTheProject() async throws {
        let f = try await changesFixture()
        await #expect(throws: GitActionError.self) {
            try await f.dispatch("editor_changes_collapse", ["root": .string("/x")])
        }
    }

    @Test func aGitRefreshMovesAVanishedHighlightToItsNeighbour() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_select", ["root": .string("/p/api"), "path": .string("a.go"),
                                                       "group": .string("staged")])
        await f.git.set(status: "/p/api", files: [("b.go", "changed", "M"), ("n", "untracked", "?")])
        await f.status.refresh(only: "/p/api")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        #expect(await highlight(f)?.path == "b.go")
    }

    @Test func refreshReadsTheStatusOnlyWhenAskedForEverything() async throws {
        let f = try await changesFixture()
        let before = await f.git.statusCount
        try await f.dispatch("editor_refresh", ["what": .string("files")])
        try await f.dispatch("editor_refresh", ["what": .string("git")])
        #expect(await f.git.statusCount == before)
        try await f.dispatch("editor_refresh", [:])
        #expect(await f.git.statusCount == before + 2, "all: one read per root")
    }

    @Test func refreshRefusesAnUnknownWhat() async throws {
        let f = try await changesFixture()
        await #expect(throws: (any Error).self) {
            try await f.dispatch("editor_refresh", ["what": .string("everything")])
        }
    }

    @Test func readPaneCarriesTheHighlightAndTheCollapsedRoots() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_collapse", ["root": .string("/p/web")])
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .object(let c)? = o["column"] else { Issue.record("no column"); return }
        #expect(c["changes_closed"] == .array([.string("/p/web")]))
        #expect(c["changes_highlight"] == .object(["root": .string("/p/api"), "path": .string("a.go"),
                                                   "group": .string("staged")]))
    }
}
```

Run: `cd app && swift test --filter EditorChangesActionsTests`. Expected: build failure
(`gitStatus:` unknown), then, once it compiles, failures on the unregistered actions.

- [ ] **Step 5: The actions**

In `EditorActions.swift`:
- `registerEditorActions` gains `gitStatus: GitStatus?` between `fileLists:` and `roots:`.
- `AppWiring` passes `gitStatus: gitStatus`.
- `editor_tree`: the schema's `view` enum becomes `files`, `search` or `changes`, and the description
  says *"switch its view (files, search or changes — the project's git changes, 3b-iii)"*.
- `editor_refresh`: in the schema, add `"what": .object(["type": .string("string"), "enum": .array([.string("all"), .string("files"), .string("git")])])`.
  Append to its description: *"what: all (the default) also re-reads git status first, then the
  pane's git state (the Changes highlight, its diff tabs and its tabs' gutter baselines); files only
  the files (the file watcher's); git only the pane's git state, against the status as it is (the git
  watcher's, which has just read it)."* At the top of the handler, after `only`:

```swift
            let what = optionalString(params, "what") ?? "all"
            guard ["all", "files", "git"].contains(what) else {
                throw EditorFilesError(description: "editor_refresh: what must be all, files or git, not \"\(what)\"")
            }
            if what == "all" { await gitStatus?.refresh(only: only) }
```

  Wrap the existing file re-read and search-mark code in `if what != "git" { … }`. Before
  `return await reply(pane)`, add `if what != "files" { await refreshGit(pane, root: only) }`.
- After `updateColumn`, add the git refresh (Tasks 3 and 6 extend it) and the row parser:

```swift
    /// The pane's git state after the window's status changed under `root` (or every root): the
    /// Changes highlight moves per Rule 6. Tasks 3 and 6 add the diff tabs and the baselines.
    @Sendable func refreshGit(_ pane: String, root: String?) async {
        let status = await gitStatus?.roots ?? []
        await updateColumn(pane, onlyIfChanged: true, asDefault: false) { c in
            c.changesHighlight = editorChangesResolve(c.changesHighlight, roots: status)
        }
    }

    /// `root`, `path` and `group` as a Changes row, refused as 3a-i refused them: a missing param, a
    /// group that is not staged, changed or untracked, or a root outside the project (naming the roots).
    @Sendable func changesRow(_ params: JSONValue, action: String) async throws -> EditorChangesRow {
        for key in ["root", "path", "group"] where optionalString(params, key) == nil {
            throw StandardActionError.missingParam(action: action, param: key)
        }
        let root = optionalString(params, "root")!, path = optionalString(params, "path")!
        let group = optionalString(params, "group")!
        guard GitGroup(rawValue: group) != nil else { throw GitActionError.unknownGroup(action: action, group: group) }
        let all = await roots()
        guard all.contains(root) else { throw GitActionError.notAProjectRoot(action: action, root: root, roots: all) }
        return EditorChangesRow(root: root, path: path, group: group)
    }

    @Sendable func projectRoot(_ params: JSONValue, action: String) async throws -> String {
        guard let root = optionalString(params, "root") else { throw StandardActionError.missingParam(action: action, param: "root") }
        let all = await roots()
        guard all.contains(root) else { throw GitActionError.notAProjectRoot(action: action, root: root, roots: all) }
        return root
    }
```

- Register the four actions after `editor_move_tab`:

```swift
    let groupSchema: JSONValue = .object(["type": .string("string"),
                                          "enum": .array(GitGroup.allCases.map { .string($0.rawValue) })])

    await registry.register(Action(
        name: "editor_changes_select",
        description: "Highlight one changed file in an editor pane's Changes view: root (absolute, one of the "
            + "active project's roots), path (relative to root) and group (staged, changed or untracked — a "
            + "partly staged file is in two). Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["root": .object(["type": .string("string")]), "path": .object(["type": .string("string")]),
                        "group": groupSchema, "pin": .object(["type": .string("boolean")])],
                       required: ["root", "path", "group"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_changes_select")
            let row = try await changesRow(params, action: "editor_changes_select")
            await updateColumn(pane, asDefault: false) { c in c.changesHighlight = row }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_changes_step",
        description: "Move an editor pane's Changes highlight delta rows (1 next, -1 previous) through every "
            + "root's changed files in order — roots in project order, a collapsed root skipped, then staged, "
            + "changed, untracked — stopping at either end. With nothing highlighted, the first row. Returns "
            + "the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["delta": .object(["type": .string("integer")])], required: ["delta"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_changes_step")
            guard let delta = jsonObject(params)?["delta"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_changes_step", param: "delta")
            }
            let status = await gitStatus?.roots ?? []
            await updateColumn(pane, asDefault: false) { c in
                c.changesHighlight = editorChangesStep(status, closed: c.changesClosed,
                                                       from: editorChangesResolve(c.changesHighlight, roots: status), by: delta)
            }
            return await reply(pane)
        }))

    for (name, closing) in [("editor_changes_collapse", true), ("editor_changes_expand", false)] {
        await registry.register(Action(
            name: name,
            description: (closing ? "Collapse" : "Expand") + " one root (root, absolute) in an editor pane's "
                + "Changes view. Kept per pane, apart from the Files tree's open folders, and saved with the "
                + "layout. Returns the pane's state.",
            kind: .control, audience: .agentReachable,
            schema: schema(["root": .object(["type": .string("string")])], required: ["root"]),
            handler: { params in
                let pane = try await editorPane(params, action: name)
                let root = try await projectRoot(params, action: name)
                await updateColumn(pane, asDefault: false) { c in
                    if closing { c.changesClosed.insert(root) } else { c.changesClosed.remove(root) }
                }
                return await reply(pane)
            }))
    }
```

- In `EditorPaneKind.readPane`, the `column` object gains two keys:

```swift
            "changes_closed": .array(c.changesClosed.sorted().map { .string($0) }),
            "changes_highlight": c.changesHighlight.map { h in
                .object(["root": .string(h.root), "path": .string(h.path), "group": .string(h.group)]) } ?? .null,
```

Every action here is `.control` or `.read` and agent-reachable. So nothing joins
`operatorOnlyActions`, and `ActionClassificationTests` covers them as they are.

Run: `cd app && swift test --filter 'EditorChangesActionsTests|EditorChangesTests|ActionClassificationTests'`.
Expected: PASS.

- [ ] **Step 6: The window — one read per wake reaches the editor panes**

In `WindowModel.swift`:
- `editorRootChanged` adds `params["what"] = .string("files")` before its loop, so the file watcher
  never reads git (R5).
- `gitRootChanged`, after `refreshGitPanes(root: root)`, adds the editor panes' git refresh:

```swift
        for pane in layoutSnapshot.panes where PaneKinds.is(pane.kind, EditorPaneKind.self) {
            _ = try? await registry.dispatch(
                name: "editor_refresh",
                params: .object(["pane": .string(pane.id), "root": .string(root), "what": .string("git")]),
                origin: .ui, environment: environment, confirmation: nil)
        }
        await refreshPanes()
```

- `toggleEditorColumn` needs no change: `.changes` passes through as `view.rawValue`.

In `WindowModelEditorTests.swift`, `editorWindow` (or the file's own builder) registers the editor
actions with a `GitStatus` over a `FakeGit`, and passes the same instance as `gitStatus:`. Add:

```swift
    @Test func cmdShiftGTogglesTheChangesViewOnCmdBsTerms() async throws {
        let w = try await editorWindow()
        await w.model.toggleEditorColumn(.changes)
        let pane = try #require(w.model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        #expect(w.model.editor(pane)?.column?.view == .changes && w.model.editor(pane)?.column?.shown == true)
        await w.model.toggleEditorColumn(.files)
        #expect(w.model.editor(pane)?.column?.view == .files)
        await w.model.toggleEditorColumn(.changes)
        await w.model.toggleEditorColumn(.changes)
        #expect(w.model.editor(pane)?.column?.shown == false)
    }

    @Test func aGitWakeReachesEveryEditorPaneOnceAndTheFileWakeReadsNoGit() async throws {
        let w = try await editorWindow()   // its builder passes a RecordingRootWatcher as rootWatcher
        await w.model.refreshContext()
        await w.model.openPane(kind: "editor")
        await w.model.openPane(kind: "editor")
        let before = await w.git.statusCount
        await w.gitWatcher.fire("/p/api")
        #expect(await w.git.statusCount == before + 1)
        await w.editorWatcher.fire("/p/api", paths: ["/p/api/a.go"])
        #expect(await w.git.statusCount == before + 1, "the file watcher reads no git")
    }
```

Give the builder the members these tests use (`git`, `gitWatcher`, `editorWatcher`) if it lacks them.
The watcher is `RecordingRootWatcher` from `WindowModelGitTests.swift`.

- [ ] **Step 7: Draw it — the Changes view, the tree's letters, ⌘⇧G**

`EditorPaneStyle` (`EditorPane.swift`) gains the git tones, copied from `GitPaneStyle.tone`:

```swift
    /// §5: amber for a change, green for an addition, a deletion muted — never red (3a-i's tones).
    static func tone(_ t: GitStatusTone) -> Color {
        switch t {
        case .modified: amber
        case .added: Color(TerminalPalette.green)
        case .muted: text.opacity(0.45)
        }
    }
```

`EditorColumn` gains `let gitRoots: [GitRootState]`:
- `EditorPane` takes it as a parameter and passes it on.
- `Canvas.swift`'s editor arm passes `model.gitRoots`, beside the other column inputs.

In `EditorColumn.body`, the view switch becomes:

```swift
                switch column.view {
                case .files: tree
                case .search: searchView
                case .changes: changesView
                }
```

In the header, add the third button after Search:

```swift
            Button("Changes") {
                focusWanted = .changes
                Task { await dispatch("editor_tree", ["view": .string("changes"), "shown": .bool(true)]) }
            }
                .buttonStyle(.plain).opacity(column.view == .changes ? 1 : 0.5)
                .accessibilityIdentifier("editor.column.changes")
```

`takeWantedKeyboard`'s last line becomes a switch: `.search` sets `queryFocused`, `.changes` sets
`changesFocused`, and `.files` sets `treeFocused`. Add `@FocusState private var changesFocused: Bool`
to the `hasKeyboard` expression.

The view, built from 3a-i's `rootHeader` and `fileRow` (moved from `GitPane.swift`, with
`GitPaneStyle` replaced by `EditorPaneStyle`):

```swift
    // MARK: - Changes (3b-iii)

    private var changesRows: [EditorChangesRow] { editorChangesRows(gitRoots, closed: column.changesClosed) }
    private var changesHighlight: EditorChangesRow? { editorChangesResolve(column.changesHighlight, roots: gitRoots) }

    private var changesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if gitRoots.isEmpty {
                        Text("No project roots to read")
                            .font(.system(size: 12)).foregroundStyle(EditorPaneStyle.text.opacity(0.46))
                    }
                    ForEach(gitRoots, id: \.root) { root in
                        changesHeader(root)
                        if !column.changesClosed.contains(root.root) {
                            ForEach(gitListSections(root), id: \.group) { section in
                                Text(gitGroupLabel(section.group))
                                    .font(.system(size: 9, weight: .medium)).tracking(1.7)
                                    .foregroundStyle(EditorPaneStyle.text.opacity(0.45))
                                    .padding(.top, 6).padding(.leading, 6)
                                ForEach(section.rows, id: \.self) { changesRow($0, root: root) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focused($changesFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in changesKey(press) }
            .onChange(of: changesHighlight) { _, now in
                if let now { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(now) } }
            }
        }
    }

    @ViewBuilder
    private func changesHeader(_ root: GitRootState) -> some View {
        let closed = column.changesClosed.contains(root.root)
        HStack(spacing: 6) {
            Image(systemName: closed ? "chevron.right" : "chevron.down").font(.system(size: 9))
            if root.loading { EditorBusyTick().accessibilityIdentifier("editor.changes.loading") }
            Text(gitRootLine(root))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.top, 10).padding(.leading, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggleRoot(root.root, closed: closed) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.changes.root:\(root.name)")
        .accessibilityAction { toggleRoot(root.root, closed: closed) }
        if let detail = gitRootErrorDetail(root) {
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.leading, 8)
                .accessibilityIdentifier("editor.changes.rootError:\(root.name)")
        }
    }

    private func toggleRoot(_ root: String, closed: Bool) {
        Task { await dispatch(closed ? "editor_changes_expand" : "editor_changes_collapse", ["root": .string(root)]) }
    }

    private func changesRow(_ row: GitFileRow, root: GitRootState) -> some View {
        let ref = EditorChangesRow(root: root.root, path: row.path, group: row.group.rawValue)
        let on = ref == changesHighlight
        return HStack(spacing: 0) {
            Text(row.status)
                .foregroundStyle(EditorPaneStyle.tone(gitStatusTone(row.status)))
                .frame(width: 18, alignment: .leading)
            Text(gitRowLabel(row))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? EditorPaneStyle.lifted : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) { if on { Rectangle().fill(EditorPaneStyle.violet).frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selectChange(ref, pin: true) }
        .onTapGesture { selectChange(ref, pin: false) }
        .id(ref)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.changes.row:\(root.name)/\(row.path):\(row.group.rawValue)")
        .accessibilityAction { selectChange(ref, pin: false) }
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(on ? [.isStaticText, .isSelected] : .isStaticText)
    }

    private func selectChange(_ ref: EditorChangesRow, pin: Bool) {
        changesFocused = true
        var p: [String: JSONValue] = ["root": .string(ref.root), "path": .string(ref.path), "group": .string(ref.group)]
        if pin { p["pin"] = .bool(true) }
        Task { await dispatch("editor_changes_select", p) }
    }

    /// ↑↓ step (and open, from Task 3); Return opens the highlighted row. Chords and other keys pass.
    private func changesKey(_ press: KeyPress) -> KeyPress.Result {
        guard !isChord(press) else { return .ignored }
        switch press.key {
        case .upArrow: Task { await dispatch("editor_changes_step", ["delta": .integer(-1)]) }
        case .downArrow: Task { await dispatch("editor_changes_step", ["delta": .integer(1)]) }
        case .return:
            guard let h = changesHighlight else { return .ignored }
            selectChange(h, pin: false)
        default: return .ignored
        }
        return .handled
    }
```

Add `static let lifted = Color(red: 0x1c / 255, green: 0x20 / 255, blue: 0x30 / 255)` to
`EditorPaneStyle` if it is not there. Use the file's own busy tick: if the column has none,
`EditorBusyTick` from `EditorPane.swift`.

**The tree's letter.** In `treeRow` (or `rowLabel`), after the name, for a file row:

```swift
            if row.kind == .file,
               let letter = editorTreeStatus(root: row.root, relative: row.relative, roots: gitRoots) {
                Spacer(minLength: 6)
                Text(letter)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.tone(gitStatusTone(letter)))
            }
```

The row's combined accessibility text then ends with the letter. Ignored files keep their dimming,
because the letter is drawn beside it, not instead.

**⌘⇧G.** In `AppScene.swift`, after the ⌘⇧F button:

```swift
                Button("Show Changes") {
                    withModel { model in Task { await model.toggleEditorColumn(.changes) } }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
```

In the comment that lists the window's keys, add ⌘⇧G.

**The page hands ⇧⌘G back** (R11). In `monaco-host.html`, in the editor-mode keydown filter:

```js
        const searchFiles = e.code === 'KeyF' && e.shiftKey;
        const changes = e.code === 'KeyG' && e.shiftKey;   // ⌘⇧G is the window's Changes view (3b-iii)
        if (plain || searchFiles || changes) { e.stopPropagation(); }
```

The comment above it adds ⌘⇧G, and notes that Monaco's Find Previous keeps ⇧⏎ in its bar.

- [ ] **Step 8: Run everything**

Run: `make build && make test && make app-test`. Expected: green.

Look at it: run `make run` (or the `run` skill) on the git e2e fixture. Expect:
- ⌘⇧G shows Changes with `e2e-git · not a git repository`, then `e2e-api` (STAGED app.txt; CHANGES
  app.txt; UNTRACKED BookingController.php, notes) and `e2e-portal`.
- ↑↓ move the violet edge.
- A header click collapses its root.
- The Files tree shows `M` beside `app.txt` and `?` beside `notes`.

- [ ] **Step 9: Commit and open PR 2**

```bash
git switch -c yehia-khalil/3b-iii-2-changes-view
git add app/Sources app/Tests
git commit -m "3b-iii PR 2: the Changes view, its actions, the tree's status letters, ⌘⇧G"
gh stack submit
```

---
### Task 3: Diff tabs — the subject, the fetch, the preview rule, liveness, ⌘⏎ (PR 3)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorDiff.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorSnapshot.swift`, `app/Sources/WakilKit/Editor/EditorTabs.swift`,
  `app/Sources/WakilKit/Editor/EditorRenderer.swift` (`editorTabKey` only),
  `app/Sources/WakilKit/Editor/EditorPaneKind.swift`, `app/Sources/WakilKit/Editor/EditorActions.swift`,
  `app/Sources/WakilKit/App/WindowModel.swift`, `app/Sources/WakilApp/AppScene.swift`
- Test: `app/Tests/WakilKitTests/EditorDiffTabsTests.swift` (new), `app/Tests/WakilKitTests/EditorTabsTests.swift`

**Interfaces:**
- Consumes:
  - Task 2: `changesRow`, `refreshGit`, `editorChangesFile`, `editorChangesStep`, `editorChangesResolve`.
  - Task 1: `GitStatus.git`.
- Produces:
  - `EditorTabSubject.diff(root: String, path: String, group: GitGroup)`, where `path` is relative to `root`.
  - `EditorTab.diffState: GitDiffState?` and `EditorTab.diff(root:path:group:) -> EditorTab`.
  - `GitDiffState` moves to `EditorDiff.swift` and gains `noLongerChanged: Bool`.
  - `editorDiffRevs(_ group: GitGroup, status: String?) -> (original: String?, modified: String?)`.
  - `editorDiffOpensFile(root:path:group:roots:) -> Bool`.
  - `editorCommandReturnOpensFile(_ s: EditorSnapshot?, roots: [GitRootState]) -> Bool`.
  - `editorTabParams(_ subject: EditorTabSubject) -> [String: JSONValue]`.
  - `EditorActionError.notADiff(action:)` and `EditorActionError.fileGone(path:)`.
  - The action `editor_open_file`. `editor_changes_select` and `editor_changes_step` now open diff tabs.
  - `WindowModel.commandReturn() async`.

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/EditorDiffTabsTests.swift` (uses `changesFixture()` from Task 2):

```swift
import Foundation
import Testing
@testable import WakilKit

private func select(_ f: EditorFixture, _ root: String, _ path: String, _ group: String, pin: Bool = false) async throws {
    var p: [String: JSONValue] = ["root": .string(root), "path": .string(path), "group": .string(group)]
    if pin { p["pin"] = .bool(true) }
    try await f.dispatch("editor_changes_select", p)
}

@Suite struct EditorDiffTabsTests {
    @Test func selectOpensAPreviewDiffTabWithBothSides() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        await f.git.set(show: "/p/api|b.go|worktree", "new\n")
        try await select(f, "/p/api", "b.go", "changed")
        let s = await f.snapshot()
        let t = try #require(s.tabs.first)
        #expect(t.subject == .diff(root: "/p/api", path: "b.go", group: .changed))
        #expect(t.preview && t.readOnly && !t.dirty)
        #expect(t.diffState?.original == "old\n" && t.diffState?.modified == "new\n" && t.diffState?.loading == false)
        #expect(editorTabTitles(s.tabs) == ["b.go (Changes)"])
    }

    @Test func theSameFilesTwoGroupsAreTwoTabs() async throws {
        let f = try await changesFixture()
        await f.git.set(status: "/p/api", files: [("x.go", "staged", "M"), ("x.go", "changed", "M")])
        await f.status.refresh(only: "/p/api")
        try await select(f, "/p/api", "x.go", "staged", pin: true)
        try await select(f, "/p/api", "x.go", "changed", pin: true)
        #expect(editorTabTitles(await f.snapshot().tabs) == ["x.go (Staged)", "x.go (Changes)"])
    }

    @Test func theNextSingleClickReplacesThePreviewAndADoubleClickPins() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "a.go", "staged")
        try await select(f, "/p/api", "b.go", "changed")
        #expect(await f.snapshot().tabs.count == 1)
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        try await select(f, "/p/web", "i.ts", "changed")
        let tabs = await f.snapshot().tabs
        #expect(tabs.count == 2 && !tabs[0].preview && tabs[1].preview)
    }

    @Test func eachGroupDiffsTheRevisionsTheSpecNames() {
        #expect(editorDiffRevs(.staged, status: "M") == ("HEAD", "index"))
        #expect(editorDiffRevs(.changed, status: "M") == ("index", "worktree"))
        #expect(editorDiffRevs(.untracked, status: "?") == (nil, "worktree"))
        #expect(editorDiffRevs(.changed, status: "D") == ("index", nil))
        #expect(editorDiffRevs(.staged, status: "D") == ("HEAD", nil))
        #expect(editorDiffRevs(.changed, status: "U") == ("HEAD", "worktree"))
    }

    @Test func aSecondSelectOfTheSameRowDoesNotFetchTwice() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed")
        let shows = await f.git.calls.filter { $0.hasPrefix("git_show") }.count
        try await select(f, "/p/api", "b.go", "changed")
        #expect(await f.git.calls.filter { $0.hasPrefix("git_show") }.count == shows)
    }

    // Rules 4 and 5: the preview slot taken by another diff cancels the first one's fetch.
    @Test func aPreviewReplacedWhileItsDiffLoadsNeverReceivesThatDiff() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|a.go|index", "A-staged\n")
        await f.git.setSlowShow(true)
        let first = Task { try await select(f, "/p/api", "a.go", "staged") }
        while await !f.git.calls.contains(where: { $0.hasPrefix("git_show /p/api a.go") }) { await Task.yield() }
        await f.git.release(path: "b.go")
        try await select(f, "/p/api", "b.go", "changed")
        await f.git.release()
        _ = try? await first.value
        let t = try #require(await f.snapshot().tabs.first)
        #expect(t.subject == .diff(root: "/p/api", path: "b.go", group: .changed))
        #expect(t.diffState?.original != "A-staged\n" && t.diffState?.modified != "A-staged\n")
    }

    // Rule 7: a path no longer changed opens, and says so.
    @Test func aRowNoLongerInItsGroupOpensReadingNoLongerChanged() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "gone.go", "changed")
        let d = try #require(await f.snapshot().tabs.first?.diffState)
        #expect(d.noLongerChanged && !d.loading)
        #expect(await !f.git.calls.contains { $0.contains("gone.go") })
    }

    @Test func aWakeReReadsEveryOpenDiffTabUnderItsRoot() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|b.go|worktree", "one\n")
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        try await select(f, "/p/web", "i.ts", "changed", pin: true)
        await f.git.set(show: "/p/api|b.go|worktree", "two\n")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        let tabs = await f.snapshot().tabs
        #expect(tabs[0].diffState?.modified == "two\n")
        #expect(!tabs[1].diffState!.loading)
    }

    @Test func aDiffWhoseFileLeftItsGroupSaysNoLongerChangedAndStaysOpen() async throws {
        let f = try await changesFixture()
        await f.git.set(show: "/p/api|b.go|worktree", "kept\n")
        try await select(f, "/p/api", "b.go", "changed")
        await f.git.set(status: "/p/api", files: [("b.go", "staged", "M")])
        await f.status.refresh(only: "/p/api")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        let t = try #require(await f.snapshot().tabs.first)
        #expect(t.diffState?.noLongerChanged == true && t.diffState?.modified == "kept\n")
    }

    @Test func stepMovesTheHighlightAndOpensItsPreviewDiff() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        try await f.dispatch("editor_changes_step", ["delta": .integer(1)])
        let s = await f.snapshot()
        #expect(s.tabs.count == 1 && s.tabs[0].subject == .diff(root: "/p/api", path: "b.go", group: .changed))
    }

    @Test func aFailedSideShowsItsErrorWhole() async throws {
        let f = try await changesFixture()
        await f.git.set(showError: "/p/api|b.go|index", "fatal: bad object\nmore")
        try await select(f, "/p/api", "b.go", "changed")
        #expect(await f.snapshot().tabs.first?.diffState?.error == "fatal: bad object\nmore")
    }

    @Test func openFileOpensTheFileAtTheDiffCursorsLine() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "1\n2\n3\n4\n")
        try await select(f, "/p/api", "b.go", "changed")
        let subject = await f.snapshot().tabs[0].subject
        await f.panes.editorViewDidReport(paneId: f.pane, subject: subject, cursor: EditorPosition(line: 3, column: 2),
                                          selection: nil, visibleRange: nil, scrollTop: 0)
        try await f.dispatch("editor_open_file")
        let s = await f.snapshot()
        #expect(s.tabs.count == 2, "the diff tab stays open beside it (Rule 6)")
        #expect(s.tabs[s.active!].path == "/p/api/b.go" && s.tabs[s.active!].cursor.line == 3)
    }

    @Test func openFileIsRefusedOnADeletedFilesDiff() async throws {
        let f = try await changesFixture()
        await f.git.set(status: "/p/api", files: [("b.go", "changed", "D")])
        await f.status.refresh(only: "/p/api")
        try await select(f, "/p/api", "b.go", "changed")
        await #expect(throws: EditorActionError.fileGone(path: "/p/api/b.go")) { try await f.dispatch("editor_open_file") }
    }

    @Test func openFileIsRefusedOnAStagedDiffWhoseFileIsGoneFromTheWorkingTree() {
        let roots = [GitRootState(root: "/p/api", name: "api", branch: "main", detached: "", ahead: 0, behind: 0,
                                  files: [GitFileRow(path: "x", origPath: nil, group: .staged, status: "M"),
                                          GitFileRow(path: "x", origPath: nil, group: .changed, status: "D")],
                                  error: nil, loading: false)]
        #expect(!editorDiffOpensFile(root: "/p/api", path: "x", group: .staged, roots: roots))
        #expect(editorDiffOpensFile(root: "/p/api", path: "y", group: .staged, roots: roots))
    }

    @Test func openFileOnAFileTabIsRefused() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "x\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await #expect(throws: EditorActionError.notADiff(action: "editor_open_file")) { try await f.dispatch("editor_open_file") }
    }

    @Test func closeAddressesADiffTabBySubject() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        try await f.dispatch("editor_close", ["diff": .object(["root": .string("/p/api"), "path": .string("b.go"),
                                                               "group": .string("changed")])])
        #expect(await f.snapshot().tabs.isEmpty)
    }

    @Test func diffTabsAreNotSavedWithTheLayout() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed", pin: true)
        #expect(editorSavedTabs(await f.snapshot()).isEmpty)
    }

    @Test func readPaneCarriesADiffTabsFactsNotItsTexts() async throws {
        let f = try await changesFixture()
        try await select(f, "/p/api", "b.go", "changed")
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .array(let tabs)? = o["tabs"], case .object(let t)? = tabs.first,
              case .object(let d)? = t["diff"] else { Issue.record("no diff"); return }
        #expect(d["root"] == .string("/p/api") && d["path"] == .string("b.go") && d["group"] == .string("changed"))
        #expect(d["loading"] == .bool(false) && d["no_longer_changed"] == .bool(false) && d["original"] == nil)
    }

    @Test func cmdReturnOpensTheFileOnlyFromADiffThatMay() {
        let ok = EditorSnapshot(tabs: [.diff(root: "/p/api", path: "b.go", group: .changed)], active: 0)
        #expect(editorCommandReturnOpensFile(ok, roots: []))
        #expect(!editorCommandReturnOpensFile(EditorSnapshot(tabs: [.scratch(number: 1, language: "plaintext")], active: 0), roots: []))
        #expect(!editorCommandReturnOpensFile(nil, roots: []))
    }
}
```

In `EditorTabsTests.swift`, add:

```swift
@Test func aDiffTabsTitleNamesItsGroupAndItsKeyIsItsOwn() {
    let t = EditorTab.diff(root: "/p/api", path: "app/User.php", group: .staged)
    #expect(editorTabTitles([t]) == ["User.php (Staged)"])
    #expect(editorTabKey(t) == "diff:staged:/p/api/app/User.php")
    #expect(editorTabParams(t.subject) == ["diff": .object(["root": .string("/p/api"), "path": .string("app/User.php"),
                                                            "group": .string("staged")])])
}
```

Run: `cd app && swift test --filter 'EditorDiffTabsTests|EditorTabsTests'`. Expected: build failure.

- [ ] **Step 2: `Editor/EditorDiff.swift`**

Move `GitDiffState` here from `GitSnapshot.swift` and add the field:

```swift
import Foundation

/// The two sides of a diff tab (3b-iii; 3a-i's `GitDiffState`, moved with its fetch). The texts are
/// large, so `read_pane` publishes only the facts about them.
public struct GitDiffState: Sendable, Equatable {
    public var original: String
    public var modified: String
    public var language: String
    public var binary: Bool
    public var bytes: Int
    public var lines: Int
    public var truncated: Bool
    public var error: String?
    public var loading: Bool
    /// The file is no longer in the tab's group (committed, staged, discarded): the tab says so and
    /// stays open until closed, its last texts kept (spec, Rule 7).
    public var noLongerChanged: Bool

    public init(original: String, modified: String, language: String, binary: Bool, bytes: Int,
                lines: Int, truncated: Bool, error: String?, loading: Bool, noLongerChanged: Bool = false) {
        self.original = original
        self.modified = modified
        self.language = language
        self.binary = binary
        self.bytes = bytes
        self.lines = lines
        self.truncated = truncated
        self.error = error
        self.loading = loading
        self.noLongerChanged = noLongerChanged
    }

    static func loading(_ language: String) -> GitDiffState {
        GitDiffState(original: "", modified: "", language: language, binary: false, bytes: 0, lines: 0,
                     truncated: false, error: nil, loading: true)
    }
}

/// The revisions a diff compares, by group (3a-i's `gitDiffRevs`, with deletions):
/// - Staged: HEAD against the index.
/// - Changes: the index against the working tree.
/// - Untracked: nothing against the working tree.
/// - Deleted (`D`): the original against nothing on the right, since nothing is left to read.
/// - Conflicted (`U`, always in Changes): HEAD against the working tree, because mid-merge the index
///   holds stages, not one version.
public func editorDiffRevs(_ group: GitGroup, status: String?) -> (original: String?, modified: String?) {
    if group == .changed, status == "U" { return ("HEAD", "worktree") }
    let deleted = status == "D"
    switch group {
    case .staged: return ("HEAD", deleted ? nil : "index")
    case .changed: return ("index", deleted ? nil : "worktree")
    case .untracked: return (nil, "worktree")
    }
}

/// Whether ⌘⏎ (`editor_open_file`) may open a diff's file. No for a deleted file's diff, or for a
/// Staged diff whose file is gone from the working tree (a `D` in Changes).
public func editorDiffOpensFile(root: String, path: String, group: GitGroup, roots: [GitRootState]) -> Bool {
    guard let r = roots.first(where: { $0.root == root }) else { return true }
    let rows = r.files.filter { $0.path == path }
    if rows.contains(where: { $0.group == .changed && $0.status == "D" }) { return false }
    if rows.first(where: { $0.group == group })?.status == "D" { return false }
    return true
}

/// ⌘⏎ in a focused editor pane (R10): open the file when the active tab is a diff that may, else
/// it is Maximize Pane as everywhere else.
public func editorCommandReturnOpensFile(_ s: EditorSnapshot?, roots: [GitRootState]) -> Bool {
    guard let s, let i = s.active, i < s.tabs.count,
          case .diff(let root, let path, let group) = s.tabs[i].subject else { return false }
    return editorDiffOpensFile(root: root, path: path, group: group, roots: roots)
}

/// A diff tab's own name for its group, in its title.
func editorDiffGroupTitle(_ g: GitGroup) -> String {
    switch g {
    case .staged: "Staged"
    case .changed: "Changes"
    case .untracked: "Untracked"
    }
}

/// One diff fetch per diff tab of each pane: a new fetch for a tab cancels its last, and a tab's
/// fetch is cancelled when its tab is replaced (Rules 4, 5).
///
/// **Synchronous, behind a lock, so it can be called inside `PaneStore.updateEditor`** — the turn
/// that writes the tab also starts the fetch that owns it (3a-i's `GitFlights`, for the same reason).
final class EditorDiffFlights: @unchecked Sendable {
    private let lock = NSLock()
    private var flights: [String: [String: Task<Void, Never>]] = [:]   // pane -> tab key -> fetch

    func start(_ pane: String, key: String, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            flights[pane]?[key]?.cancel()
            let task = Task { await body() }
            flights[pane, default: [:]][key] = task
            return task
        }
    }

    func cancel(_ pane: String, key: String) {
        lock.withLock { _ = flights[pane]?.removeValue(forKey: key).map { $0.cancel() } }
    }

    func drop(_ pane: String) {
        lock.withLock { flights.removeValue(forKey: pane)?.values.forEach { $0.cancel() } }
    }
}
```

- [ ] **Step 3: The subject and the tab**

In `EditorSnapshot.swift`:

```swift
public enum EditorTabSubject: Sendable, Equatable, Hashable {
    case file(path: String, root: String)
    case scratch(number: Int)
    /// A Changes diff (3b-iii): `path` relative to `root`, in one group. Read-only, never saved.
    case diff(root: String, path: String, group: GitGroup)
}
```

`EditorTab` gains `public var diffState: GitDiffState?`, documented as *"A diff tab's two sides; nil
for every other tab"*. It joins `init` as a last parameter, `diffState: GitDiffState? = nil`. Add the
factory:

```swift
    /// A diff tab, its two sides loading. Read-only and never dirty: its text is not a buffer.
    public static func diff(root: String, path: String, group: GitGroup) -> EditorTab {
        let language = editorLanguage(forPath: path)
        return EditorTab(subject: .diff(root: root, path: path, group: group), text: "", savedText: "",
                         language: language, diskState: .inSync, mtime: 0, cursor: EditorPosition(line: 1, column: 1),
                         selection: nil, visibleRange: nil, scrollTop: 0, notice: nil, readOnly: true, saving: false,
                         edits: 0, lastAgentEdit: nil, diffState: .loading(language))
    }
```

`path` and `isScratch` stay as they are: a diff tab has no `path`, so it is never saved and never
matched by a file action.

**The compiler lists every `switch` over a subject.** Handle each like this:
- `editorTabTitles`: `case .diff(_, let path, let group): return "\((path as NSString).lastPathComponent) (\(editorDiffGroupTitle(group)))"`.
- `editorTabKey`: `case .diff(let root, let path, let group): "diff:\(group.rawValue):\(root)/\(path)"`.
- `EditorPaneKind.readPane`'s tab object: `path`, `root` and `scratch` stay null for a diff tab.
  Add a `"diff"` key on every tab, null except on a diff tab:

```swift
            var diff: JSONValue = .null
            if case .diff(let r, let p, let g) = tab.subject, let d = tab.diffState {
                diff = .object([
                    "root": .string(r), "path": .string(p), "group": .string(g.rawValue),
                    "loading": .bool(d.loading), "error": d.error.map { .string($0) } ?? .null,
                    "binary": .bool(d.binary), "bytes": .number(Double(d.bytes)), "lines": .number(Double(d.lines)),
                    "truncated": .bool(d.truncated), "no_longer_changed": .bool(d.noLongerChanged),
                    "language": .string(d.language)])
            }
```

- `WindowModel`'s two `switch subject` sites that build `editor_close` params use
  `editorTabParams(subject)` (below) instead.
- `PaneFetch.swift:78` switches over another subject type; leave it.

In `EditorTabs.swift`:

```swift
/// The params that name `subject`'s tab to `editor_close` (and every action that takes a tab): path,
/// scratch, or a diff's root, path and group.
public func editorTabParams(_ subject: EditorTabSubject) -> [String: JSONValue] {
    switch subject {
    case .file(let path, _): ["path": .string(path)]
    case .scratch(let n): ["scratch": .integer(Int64(n))]
    case .diff(let root, let path, let group):
        ["diff": .object(["root": .string(root), "path": .string(path), "group": .string(group.rawValue)])]
    }
}
```

In `EditorActions.swift`:
- `editorTabIndex` gains `diff: EditorTabSubject? = nil`, matched first:
  `if let diff { return s.tabs.firstIndex { $0.subject == diff } }`.
- Add the param reader:

```swift
    /// The optional `diff` param ({root, path, group}): a diff tab by its subject.
    @Sendable func tabDiff(_ params: JSONValue) -> EditorTabSubject? {
        guard case .object(let d)? = jsonObject(params)?["diff"], case .string(let r)? = d["root"],
              case .string(let p)? = d["path"], case .string(let g)? = d["group"], let group = GitGroup(rawValue: g)
        else { return nil }
        return .diff(root: r, path: p, group: group)
    }
```

- `editor_close` passes `diff: tabDiff(params)` to `editorTabIndex`. Its schema gains
  `"diff": .object(["type": .string("object")])`, and its description gains *"or diff: {root, path,
  group}, a Changes diff tab"*.

- [ ] **Step 4: The fetch, the open, and liveness**

In `registerEditorActions`, after `changesRow`:

```swift
    let diffFlights = EditorDiffFlights()
    await panes.onDrop { pane in diffFlights.drop(pane) }

    /// Fetches `subject`'s two sides into its tab, as that tab's one flight. Called only inside the
    /// `updateEditor` turn that wrote the tab (see `EditorDiffFlights`). A reply that lands after its
    /// tab is gone, or after a newer fetch for it began, writes nothing.
    @Sendable func fetchDiff(_ pane: String, _ subject: EditorTabSubject, status: String?) -> Task<Void, Never>? {
        guard case .diff(let root, let path, let group) = subject, let git = gitStatus?.git else { return nil }
        let revs = editorDiffRevs(group, status: status)
        let language = editorLanguage(forPath: path)
        @Sendable func side(_ rev: String?) async throws -> FilesOutcome {
            guard let rev else { return .ok([:]) }
            return try await filesTool(git, "git_show", ["root": .string(root), "path": .string(path), "rev": .string(rev)])
        }
        let key = "diff:\(group.rawValue):\(root)/\(path)"
        return diffFlights.start(pane, key: key) {
            let outcome: (FilesOutcome, FilesOutcome)
            do {
                async let o = side(revs.original)
                async let m = side(revs.modified)
                outcome = try await (o, m)
            } catch {
                return   // cancelled: the fetch that replaced this one owns the tab now
            }
            if Task.isCancelled { return }
            await panes.updateEditor(paneId: pane) { s in
                guard !Task.isCancelled, let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
                let gone = s.tabs[i].diffState?.noLongerChanged ?? false
                switch outcome {
                case (.failed(let text), _), (_, .failed(let text)):
                    s.tabs[i].diffState = GitDiffState(original: "", modified: "", language: language, binary: false,
                                                       bytes: 0, lines: 0, truncated: false, error: text, loading: false,
                                                       noLongerChanged: gone)
                case (.ok(let o), .ok(let m)):
                    func text(_ x: [String: JSONValue]) -> String { if case .string(let t)? = x["text"] { t } else { "" } }
                    func lines(_ t: String) -> Int { t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count }
                    let original = text(o), modified = text(m)
                    s.tabs[i].diffState = GitDiffState(
                        original: original, modified: modified, language: language,
                        binary: o["binary"] == .bool(true) || m["binary"] == .bool(true),
                        bytes: max(o["bytes"]?.intValue ?? 0, m["bytes"]?.intValue ?? 0),   // a deletion's size is its original's
                        lines: max(lines(original), lines(modified)),
                        truncated: o["truncated"] == .bool(true) || m["truncated"] == .bool(true),
                        error: nil, loading: false, noLongerChanged: gone)
                }
            }
        }
    }

    /// Opens `row`'s diff tab under the preview rule (3b-ii): a tab already open is focused (and
    /// pinned by `pin`) and not fetched again (Rule 5); otherwise a preview takes the pane's clean
    /// preview slot, cancelling the fetch of what it held, and a pinned one is added. A row no longer
    /// in its group opens reading "No longer changed" (Rule 7), fetching nothing.
    @Sendable func openDiff(_ pane: String, _ row: EditorChangesRow, pin: Bool) async {
        let group = GitGroup(rawValue: row.group)!
        let subject = EditorTabSubject.diff(root: row.root, path: row.path, group: group)
        let status = await gitStatus?.roots ?? []
        let file = editorChangesFile(row, in: status)
        let listed = status.first { $0.root == row.root }.map { !($0.loading && $0.files.isEmpty) } ?? false
        let gone = listed && file == nil
        let flight: Task<Void, Never>? = await panes.updateEditor(paneId: pane, create: true) { s in
            if let i = s.tabs.firstIndex(where: { $0.subject == subject }) {
                s.active = i
                if pin { s.tabs[i].preview = false }
                return nil
            }
            var tab = EditorTab.diff(root: row.root, path: row.path, group: group)
            tab.preview = !pin
            if gone { tab.diffState?.loading = false; tab.diffState?.noLongerChanged = true }
            if !pin, let p = s.tabs.firstIndex(where: { $0.preview && !$0.dirty }) {
                diffFlights.cancel(pane, key: editorTabKey(s.tabs[p]))
                s.tabs[p] = tab
                s.active = p
            } else {
                s.tabs.append(tab)
                s.active = s.tabs.count - 1
            }
            return gone ? nil : fetchDiff(pane, subject, status: file?.status)
        }
        await updateColumn(pane, asDefault: false) { c in c.changesHighlight = row }
        await persist(pane)     // a preview file tab may have been replaced
        await flight?.value
    }
```

`refreshGit` (Task 2) grows the diff tabs' re-read:

```swift
    @Sendable func refreshGit(_ pane: String, root: String?) async {
        let status = await gitStatus?.roots ?? []
        await updateColumn(pane, onlyIfChanged: true, asDefault: false) { c in
            c.changesHighlight = editorChangesResolve(c.changesHighlight, roots: status)
        }
        // Every open diff tab under the root re-reads, keeping its texts while it loads (no blank flash).
        // One whose file left its group says so, keeps its texts, and is not fetched (spec, Rule 7).
        let flights: [Task<Void, Never>] = await panes.updateEditor(paneId: pane) { s in
            var started: [Task<Void, Never>] = []
            for i in s.tabs.indices {
                guard case .diff(let r, let p, let g) = s.tabs[i].subject, root == nil || r == root,
                      status.contains(where: { $0.root == r }) else { continue }
                let row = EditorChangesRow(root: r, path: p, group: g.rawValue)
                guard let file = editorChangesFile(row, in: status) else {
                    s.tabs[i].diffState?.noLongerChanged = true
                    s.tabs[i].diffState?.loading = false
                    continue
                }
                s.tabs[i].diffState?.noLongerChanged = false
                s.tabs[i].diffState?.loading = true
                if let t = fetchDiff(pane, s.tabs[i].subject, status: file.status) { started.append(t) }
            }
            return started
        }
        for f in flights { await f.value }
    }
```

`editor_changes_select` opens the tab. Its description becomes *"Open one changed file's diff in an
editor pane, as a read-only diff tab titled `name (Changes)`, `(Staged)` or `(Untracked)`:
root (absolute, one of the active project's roots), path (relative to root), group (staged, changed
or untracked — a partly staged file is in two). Staged compares HEAD with the index, changed the
index with the working tree (a conflicted file HEAD with the working tree), untracked nothing with
the working tree; a deleted file is compared with nothing. A preview tab, replaced by the next one,
unless pin is true. A file no longer in that group opens reading No longer changed. The Changes
highlight moves to it. Returns the pane's state; the diff's texts are not in it — read them with
git_show."* The handler body becomes:

```swift
            let pane = try await editorPane(params, action: "editor_changes_select")
            let row = try await changesRow(params, action: "editor_changes_select")
            await openDiff(pane, row, pin: jsonObject(params)?["pin"] == .bool(true))
            return await reply(pane)
```

`editor_changes_step`: after `updateColumn`, open the highlighted row as a preview. Append *"and
open its diff as a preview tab, as editor_changes_select does"* to the description.

```swift
            let c = await updateColumn(pane, asDefault: false) { c in … }   // as in Task 2, now keeping the result
            if let h = c.changesHighlight { await openDiff(pane, h, pin: false) }
```

**`editor_open_file`.** First, lift `editor_open`'s body (from `let line =` through `await persist(pane)`)
into a local function. `editor_open`'s handler then calls it, with its own parsed values:

```swift
    /// Opens `path` in `pane` — focusing its tab if open — with the cursor at `at` and `selection`, as a
    /// preview when asked (3b-ii). `editor_open`'s body, shared with `editor_open_file`.
    @Sendable func openFile(_ pane: String, path: String, at line: EditorPosition?, selection: EditorRange?,
                            preview: Bool) async throws {
        @Sendable func place(_ t: inout EditorTab) {
            guard let line else { return }
            t.cursor = selection?.end ?? line
            if let selection { t.selection = selection }
        }
        let keep = !preview
        let focused = await panes.updateEditor(paneId: pane, create: true) { s -> Bool in
            guard let i = s.tabs.firstIndex(where: { $0.path == path }) else { return false }
            s.active = i
            place(&s.tabs[i])
            if keep { s.tabs[i].preview = false }
            return true
        }
        if !focused {
            var fresh = try await read(path, action: "editor_open")
            place(&fresh)
            let tab = fresh
            await panes.updateEditor(paneId: pane, create: true) { s in
                if let i = s.tabs.firstIndex(where: { $0.path == path }) {
                    s.active = i
                } else if preview, let p = s.tabs.firstIndex(where: { $0.preview && !$0.dirty }) {
                    diffFlights.cancel(pane, key: editorTabKey(s.tabs[p]))
                    var t = tab; t.preview = true
                    s.tabs[p] = t
                    s.active = p
                } else {
                    var t = tab; t.preview = preview
                    s.tabs.append(t)
                    s.active = s.tabs.count - 1
                }
            }
        }
        await persist(pane)
    }
```

`openFile` sits after `fetchDiff` and `diffFlights`, so a file preview that takes a diff's slot
cancels that diff's fetch. `editor_open`'s registration stays where it is: Swift local functions
declared later in the same scope are visible to closures registered earlier only if they are
declared before use. **So move `let diffFlights`, `fetchDiff`, `openDiff` and `openFile` above
`editor_open`'s registration**, together with `changesRow` and `refreshGit` (Task 2), which
`editor_refresh` uses.

Then register:

```swift
    await registry.register(Action(
        name: "editor_open_file",
        description: "From the editor pane's active diff tab (a Changes diff), open its file as a file tab at "
            + "the line under the diff's cursor; the diff tab stays open. Refused on a deleted file's diff and "
            + "on a Staged diff whose file is gone from the working tree. ⌘⏎ in a diff tab. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_open_file")
            let snap = await panes.editorSnapshot(paneId: pane)
            guard let i = editorTabIndex(snap, path: nil) else { throw EditorActionError.noTab(action: "editor_open_file") }
            guard case .diff(let root, let path, let group) = snap.tabs[i].subject else {
                throw EditorActionError.notADiff(action: "editor_open_file")
            }
            let full = root + "/" + path
            guard editorDiffOpensFile(root: root, path: path, group: group, roots: await gitStatus?.roots ?? []) else {
                throw EditorActionError.fileGone(path: full)
            }
            try await openFile(pane, path: full, at: EditorPosition(line: snap.tabs[i].cursor.line, column: 1),
                               selection: nil, preview: false)
            return await reply(pane)
        }))
```

`EditorActionError` gains these cases:

```swift
    /// `editor_open_file` from a tab that is not a Changes diff.
    case notADiff(action: String)
    /// `editor_open_file` on a diff whose file is gone from the working tree.
    case fileGone(path: String)
```

Their descriptions:
- `"\(action): the active tab is not a Changes diff; it opens a diff's file"`
- `"editor_open_file: \(path) is deleted in the working tree, so there is no file to open"`

`editor_save` on a diff tab is refused by its existing read-only check: the tab is read-only with no
notice, so the message names the file. Check that the message reads sensibly with an empty `path`.
If it does not, pass `editorTabTitles([tab])[0]` for a diff tab.

- [ ] **Step 5: ⌘⏎ in the window**

In `WindowModel.swift`:

```swift
    /// ⌘⏎ (R10): in a focused editor pane whose active tab is a diff that may open its file, opens it
    /// (`editor_open_file`); anywhere else, Maximize Pane as before.
    public func commandReturn() async {
        guard let id = layoutSnapshot.focusedId else { return }
        if let pane = focusedEditor, editorCommandReturnOpensFile(editor(pane), roots: gitRoots) {
            _ = await dispatch("editor_open_file", .object(["pane": .string(pane)]))
            await refreshLayout()
            await refreshPanes()
            return
        }
        await toggleMaximize(id: id)
    }
```

In `AppScene.swift`, *Maximize Pane*'s action becomes
`withModel { model in Task { await model.commandReturn() } }`. Its title stays. The comment above it
says ⌘⏎ opens a diff's file in a focused editor pane on a diff (3b-iii).

In `WindowModelEditorTests`, add `cmdReturnOnADiffOpensItsFileAndElsewhereMaximizes`. It opens a diff
tab via `dispatchFromSurface("editor_changes_select", …)`, calls `commandReturn()`, and expects a file
tab and no maximized pane. Then, on a scratch tab, `commandReturn()` maximizes.

Run: `cd app && swift test --filter 'EditorDiffTabsTests|EditorTabsTests|EditorChangesActionsTests|WindowModelEditorTests|EditorActionsTests'`.
Expected: PASS.

- [ ] **Step 6: Commit (PR 3 continues with Tasks 4 and 5)**

```bash
git switch -c yehia-khalil/3b-iii-3-diff-tabs
git add app/Sources app/Tests
git commit -m "3b-iii PR 3 (1/3): diff tabs — the subject, the fetch, the preview rule, liveness, ⌘⏎"
```

---
### Task 4: One web view per pane — the diff editor in the editor's page; Compare moves onto it (PR 3)

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorRenderer.swift`
- Modify: `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `app/Sources/WakilApp/monaco-host.html`,
  `app/Sources/WakilApp/EditorPane.swift`
- Test: `app/Tests/WakilKitTests/EditorRendererTests.swift`

**Interfaces:**
- Consumes (Task 3): `EditorTab.diffState`, and `editorTabKey` for diff tabs.
- Produces:
  - `EditorRenderer.showDiff(key:original:modified:language:)` and `EditorRenderer.captureKeys(_ keys: [String])`.
  - `EditorRenderStep.diff(key:original:modified:language:)`.
  - `EditorRendered.original: String?`.
  - `editorCapturedKeys(comparing: Bool, peek: Bool) -> [String]`.
  - `MonacoEditorRenderer.onKey: ((String) -> Void)?` and `MonacoEditorRenderer.jsString(_:)`, moved
    from `MonacoDiffRenderer`, as is `compileNetworkBlock()`.

- [ ] **Step 1: Write the failing tests**

In `EditorRendererTests.swift` (its file's helpers build snapshots; add a diff-tab one):

```swift
private func diffTab(_ d: GitDiffState) -> EditorTab {
    var t = EditorTab.diff(root: "/p/api", path: "b.go", group: .changed)
    t.diffState = d
    return t
}
private func loaded(_ o: String, _ m: String) -> GitDiffState {
    GitDiffState(original: o, modified: m, language: "go", binary: false, bytes: 1, lines: 1, truncated: false,
                 error: nil, loading: false)
}

@Test func aDiffTabIsShownInTheDiffEditorAndNeverAsAModel() {
    let s = EditorSnapshot(tabs: [diffTab(loaded("a\n", "b\n"))], active: 0)
    let steps = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    #expect(steps == [.diff(key: "diff:changed:/p/api/b.go", original: "a\n", modified: "b\n", language: "go")])
}

@Test func theSameDiffReDeliveredIsNoStep() {
    let s = EditorSnapshot(tabs: [diffTab(loaded("a\n", "b\n"))], active: 0)
    let steps = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    let after = editorRenderedAfter(steps, rendered: [:], snapshot: s)
    #expect(editorRenderSteps(rendered: after, active: "diff:changed:/p/api/b.go", snapshot: s).isEmpty)
}

// The last file's diff must not sit under the new file's name while the new one loads (3a-i).
@Test func aDiffStillLoadingWhenFirstShownShowsNothing() {
    var d = loaded("", ""); d.loading = true
    let s = EditorSnapshot(tabs: [diffTab(d)], active: 0)
    #expect(editorRenderSteps(rendered: [:], active: nil, snapshot: s)
        == [.diff(key: "diff:changed:/p/api/b.go", original: "", modified: "", language: "plaintext")])
}

@Test func aRefreshLoadingTheShownDiffKeepsIt() {
    let s = EditorSnapshot(tabs: [diffTab(loaded("a\n", "b\n"))], active: 0)
    let after = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    var reloading = s; reloading.tabs[0].diffState?.loading = true
    #expect(editorRenderSteps(rendered: after, active: "diff:changed:/p/api/b.go", snapshot: reloading).isEmpty)
}

@Test func anErrorOrABinaryDiffShowsAnEmptyDiffBesideItsBanner() {
    var d = loaded("x", "y"); d.binary = true
    let s = EditorSnapshot(tabs: [diffTab(d)], active: 0)
    #expect(editorRenderSteps(rendered: [:], active: nil, snapshot: s)
        == [.diff(key: "diff:changed:/p/api/b.go", original: "", modified: "", language: "go")])
}

@Test func leavingADiffForAFileTabShowsTheModelAgain() {
    let file = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "x", mtime: 1, language: "go")
    let s = EditorSnapshot(tabs: [diffTab(loaded("a", "b")), file], active: 0)
    let r = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    var onFile = s; onFile.active = 1
    let steps = editorRenderSteps(rendered: r, active: "diff:changed:/p/api/b.go", snapshot: onFile)
    #expect(steps.first == .show(key: "file:/p/api/a.go", text: "x", language: "go", readOnly: false))
}

@Test func thePageTakesOnlyTheKeysAnOpenPeekOrCompareNeeds() {
    #expect(editorCapturedKeys(comparing: false, peek: false) == [])
    #expect(editorCapturedKeys(comparing: true, peek: false) == ["escape"])
    #expect(editorCapturedKeys(comparing: false, peek: true) == ["up", "down", "escape"])
}
```

Run: `cd app && swift test --filter EditorRendererTests`. Expected: build failure.

- [ ] **Step 2: The seam**

In `EditorRenderer.swift`:
- The protocol gains:

```swift
    /// Show a two-sided inline diff (a diff tab, or Compare) in the pane's diff editor, the code editor
    /// hidden until the next `showModel`. `key` names what is shown: the same key shown again keeps
    /// its scroll (a refresh, Rule 6).
    func showDiff(key: String, original: String, modified: String, language: String)
    /// The keys the page takes from Monaco and posts back (`editorCapturedKeys`): ↑ ↓ Esc while the
    /// peek is open, Esc while Compare is. Told only on a change.
    func captureKeys(_ keys: [String])
```

- `EditorRenderStep` gains `case diff(key: String, original: String, modified: String, language: String)`.
- `EditorRendered` gains `public var original: String?`, documented as *"A diff's original side; nil
  for a model"*. It is the last init parameter, defaulting to nil.
- In `editorRenderSteps`, the active-tab block starts with the diff case:

```swift
    if let i = snapshot.active, i < snapshot.tabs.count {
        let t = snapshot.tabs[i], key = editorTabKey(t)
        if let d = t.diffState {
            let r = rendered[key]
            if d.loading {
                // A refresh keeps the shown diff; a diff never shown yet shows nothing, so the last
                // file's diff never sits under this one's name (3a-i).
                if key != active || r == nil {
                    steps.append(.diff(key: key, original: "", modified: "", language: "plaintext"))
                }
            } else {
                let empty = d.error != nil || d.binary
                let o = empty ? "" : d.original, m = empty ? "" : d.modified
                if key != active || r?.original != o || r?.text != m {
                    steps.append(.diff(key: key, original: o, modified: m, language: t.language))
                }
            }
        } else if let r = rendered[key] {
            … (unchanged)
        } else {
            … (unchanged)
        }
        // the find step, unchanged
    }
```

- In `editorRenderedAfter`, for the active tab:

```swift
    if let i = snapshot.active, i < snapshot.tabs.count {
        let t = snapshot.tabs[i], key = editorTabKey(t)
        if t.diffState != nil {
            for case .diff(let k, let o, let m, let language) in steps where k == key {
                out[key] = EditorRendered(text: m, language: language, readOnly: true, agentSerial: 0,
                                          cursor: t.cursor, selection: nil, original: o)
            }
        } else {
            out[key] = … (unchanged)
        }
    }
```

- `editorApply` gains `case .diff(let key, let o, let m, let language): renderer.showDiff(key: key, original: o, modified: m, language: language)`.
- Add:

```swift
/// The keys the page takes from Monaco (R13): ↑ ↓ and Esc while the peek is open, Esc while Compare
/// is. Nothing else, so Monaco keeps every other key.
public func editorCapturedKeys(comparing: Bool, peek: Bool) -> [String] {
    if peek { return ["up", "down", "escape"] }
    return comparing ? ["escape"] : []
}
```

- [ ] **Step 3: The page — the diff editor beside the code editor**

In `monaco-host.html`:
- **Delete the whole diff-mode tail**: everything after the editor branch's `return;` up to the
  closing `});` of `require`. That is the diff editor, the probe code, `wakilShowDiff`/`wakilClear`,
  the key capture and the net probe.
- **Unwrap the editor branch**: drop `if (window.wakilMode === 'editor') {` and its closing `return; }`.
  The page now has one mode. Update its comment: *"One code editor and one diff editor per page
  (3b-iii): the active tab chooses which is visible."*
- The `<style>` gains the diff layer:
  `#dd{position:absolute;inset:0;display:none;background:#0b0d14}`.

Inside the (now unconditional) editor code, after `const ed = …`:

```js
      // 3b-iii: the pane's diff editor, in the same page as the code editor — a diff tab and Compare
      // show here. The active tab chooses which is visible; no second page is ever loaded.
      const codeHost = document.getElementById('d');
      const dd = document.createElement('div'); dd.id = 'dd'; document.body.appendChild(dd);
      const diff = monaco.editor.createDiffEditor(dd, {
        theme: 'wakil', readOnly: true, originalEditable: false, renderSideBySide: false,
        automaticLayout: true, minimap: { enabled: false }, fontFamily: 'Menlo, monospace', fontSize: 12
      });
      const dme = diff.getModifiedEditor();
      let diffKey = null;        // what the diff editor shows; null while the code editor is visible
      let diffScroll = null;     // re-applied once a re-shown diff is computed (its view zones move it)
      diff.onDidUpdateDiff(function () { if (diffScroll !== null) { dme.setScrollTop(diffScroll); diffScroll = null; } });
      // The diff's cursor, so ⌘⏎ opens the file at that line (editor_open_file).
      dme.onDidChangeCursorPosition(function () {
        if (!diffKey) return;
        const p = dme.getPosition();
        post({ type: 'view', key: diffKey, cursor: p ? { line: p.lineNumber, column: p.column } : { line: 1, column: 1 },
               selection: null, visible: null, scrollTop: dme.getScrollTop() });
      });
      function showCode() { dd.style.display = 'none'; codeHost.style.display = 'block'; diffKey = null; }
      window.wakilShowDiff = function (key, original, modified, language) {
        diffScroll = key === diffKey ? dme.getScrollTop() : null;
        const old = diff.getModel();
        diff.setModel({ original: monaco.editor.createModel(original, language),
                        modified: monaco.editor.createModel(modified, language) });
        if (old) { old.original.dispose(); old.modified.dispose(); }
        diffKey = key;
        current = null;          // the code editor reports nothing while it is hidden
        codeHost.style.display = 'none';
        dd.style.display = 'block';
      };
      // The keys the app asks for (editorCapturedKeys), taken before Monaco's own and posted back.
      let captured = [];
      window.wakilCaptureKeys = function (keys) { captured = keys; };
      window.addEventListener('keydown', function (e) {
        if (!captured.length || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
        const key = { ArrowUp: 'up', ArrowDown: 'down', Escape: 'escape' }[e.key];
        if (!key || captured.indexOf(key) < 0) return;
        e.preventDefault();
        e.stopPropagation();
        post({ type: 'key', key: key });
      }, true);
```

- `wakilShowModel` calls `showCode();` first.
- `wakilFocus` focuses `dme` when `diffKey` is set, else `ed`.
- `wakilSetOptions` also calls `diff.updateOptions({ fontSize: o.fontSize, wordWrap: o.wordWrap ? 'on' : 'off' })`.
- The ⌘P/⌘K pass-through that lived in the deleted tail is already in the editor's keydown filter
  (`KeyP`, `KeyK`), so nothing is lost.

- [ ] **Step 4: The renderer**

In `MonacoEditorRenderer.swift`:
- Move `compileNetworkBlock()` and `jsString(_:)` here from `MonacoDiffRenderer` as `static` members.
  `js(_:)` calls the local `jsString`. `EditorHost.start` calls `MonacoEditorRenderer.compileNetworkBlock()`.
- Drop the `window.wakilMode = 'editor'` user script, since the page has one mode now. Keep the
  network block.
- Add:

```swift
    /// A key the page took from Monaco (`captureKeys`): "up", "down" or "escape".
    var onKey: ((String) -> Void)?
    private var capturing: [String] = []

    func showDiff(key: String, original: String, modified: String, language: String) {
        run("wakilShowDiff(\([key, original, modified, language].map(Self.jsString).joined(separator: ",")))")
    }

    func captureKeys(_ keys: [String]) {
        guard keys != capturing else { return }
        capturing = keys
        run("wakilCaptureKeys([\(keys.map(Self.jsString).joined(separator: ","))])")
    }
```

- In `receive`, add `case "key": if let key = body["key"] as? String { onKey?(key) }`.

- [ ] **Step 5: The pane — one host; Compare on it (R2)**

In `EditorPane.swift`:
- Delete `compareHost` (the `GitDiffHost`) and every use of it.
- `EditorHost` gains:

```swift
    /// The pane's key handler for keys the page took (`captureKeys`), re-handed by the view.
    @ObservationIgnored var onKey: ((String) -> Void)?

    /// Compare is on screen: snapshots are kept (`latest`) but not rendered, or the next one — a
    /// keystroke's echo, a view report — would put the active tab back over Compare.
    @ObservationIgnored private var comparing = false

    /// Shows `original` ↔ `modified` in the diff editor as Compare (R2), outside the tab render.
    func showCompare(original: String, modified: String, language: String) {
        comparing = true
        renderer?.showDiff(key: "compare", original: original, modified: modified, language: language)
        active = nil   // when Compare ends, the active tab is shown again, as a switch would show it
    }

    /// Back from Compare: the active tab is shown again.
    func endCompare() {
        comparing = false
        active = nil
        if let latest { apply(latest) }
    }
```

  In `start()`, `made.onKey = { [weak self] key in self?.onKey?(key) }`. In `apply(_:)`, right
  after `latest = snapshot` and the `subjects` line, add `guard !comparing else { return }`.
- `openCompare` drops `await compareHost.start()`. It sets `host.onKey = { key in if key == "escape" { closeCompare() } }`.
  `showCompare()` becomes
  `host.showCompare(original: c.disk, modified: tab.text, language: tab.language)`.
  `closeCompare()` calls `host.endCompare()` and then `host.focus()`.
- The captured keys follow the pane's state: in `body`, add
  `.onChange(of: comparing != nil, initial: true) { _, on in host.renderer?.captureKeys(editorCapturedKeys(comparing: on, peek: false)) }`.
  Task 7 adds the peek.
- `editorStack` draws one host for both, so Compare's header sits over the same web view:

```swift
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if let comparing { compareHeader(comparing) }
                    if let tab = activeTab, let d = tab.diffState { diffLine(tab, d) }
                    GitDiffHostView(webView: host.renderer?.webView)
                        .accessibilityIdentifier(comparing != nil ? "editor.compare.diff" : "editor.monaco")
                }
                if snapshot.tabs.isEmpty, comparing == nil { emptyState }
            }
```

  `compareView` becomes `compareHeader`: the same `HStack` with the title and Close, and no host view.
  `resignKeyboard(alsoFrom:)` passes `nil`.

  `GitDiffHostView` moves from `GitPane.swift` to the bottom of `EditorPane.swift`. Its container's
  background becomes `EditorPaneStyle.slab`.
- **The diff tab's line**, drawn over the host:

```swift
    /// A diff tab's state: Loading (Rule 5), its error whole (Rule 8), the binary or truncated
    /// banner (3a-i), or "No longer changed".
    @ViewBuilder
    private func diffLine(_ tab: EditorTab, _ d: GitDiffState) -> some View {
        if d.loading {
            HStack(spacing: 6) { EditorBusyTick(); lineText("Loading") }.accessibilityIdentifier("editor.diff.loading")
        } else if let error = d.error {
            lineText(error).accessibilityIdentifier("editor.diff.error")
        } else if let banner = gitDiffBanner(d) {
            lineText(banner).accessibilityIdentifier("editor.diff.banner")
        }
        if d.noLongerChanged { lineText("No longer changed").accessibilityIdentifier("editor.diff.gone") }
    }
```

- [ ] **Step 6: Run and look**

Run: `cd app && swift test --filter EditorRendererTests`, then `make app-test`. Expected: PASS.

Run the app on the git fixture and check:
- Changes → click `app.txt` under CHANGES: one tab `app.txt (Changes)` with an inline diff, the added
  line green and the removed one muted.
- Click the STAGED row: the preview is replaced.
- Click a file in Files: the code editor returns.
- Make a tab `changedOnDisk` and press Compare: it opens in the same pane, and Esc closes it.

- [ ] **Step 7: Commit**

```bash
git add app/Sources app/Tests
git commit -m "3b-iii PR 3 (2/3): one web view per editor pane — the diff editor in the editor's page; Compare moves onto it"
```

---

### Task 5: The Git pane kind is deleted; saved Git panes migrate; the palette and vocabulary read the window's status (PR 3)

**Files:**
- Delete:
  - `app/Sources/WakilKit/Git/GitPaneKind.swift`, `Git/PaneStore+Git.swift`, `Git/GitNavigation.swift`,
    `Git/DiffRenderer.swift`, `Git/GitActions.swift`, `Git/GitSnapshot.swift`;
  - `app/Sources/WakilApp/GitPane.swift`, `MonacoDiffRenderer.swift`, `MonacoProbe.swift`;
  - the `--probe-monaco` block in `main.swift`.
- Delete tests: `GitActionsTests.swift`, `GitPaneSnapshotTests.swift`, `GitNavigationTests.swift`. Their
  surviving rules are ported in Tasks 1–2.
- Modify:
  - `Git/GitPaneLines.swift` keeps `gitRootLine`, `gitRootErrorDetail`, `gitGroupLabel`, `GitListSection`,
    `gitListSections`, `gitRowLabel`, `GitStatusTone`, `gitStatusTone`, `gitDiffBanner`, `gitByteSize`
    and `gitFileRow` (rewritten below). Delete the rest.
  - `Git/GitSource.swift`, `App/PaneKinds.swift`, `Layout/Pane.swift`, `Layout/LayoutPersistence.swift`,
    `Layout/LayoutStore.swift`, `App/WindowModel.swift`, `App/AppWiring.swift`.
  - `Command/PaletteSources.swift`, `Command/PaletteEntry.swift`, `Command/CommandCatalog.swift`,
    `Command/PaletteSearch.swift`.
  - `WakilApp/Canvas.swift`, `WakilApp/Landing.swift`, `WakilApp/Palettes.swift` (wherever
    `.openGitAndSelect` is switched on).
- Modify tests (git references, listed in Step 6).
- Delete e2e: `e2e/checks/seeded/3a-i-git-{list,drill,keys,live,press}.jsonl`,
  `e2e/checks/agent/3a-i-git-voice-hint.jsonl`, `e2e/checks/seeded/palette-new-git-parity.jsonl`, and
  their proofs under `e2e/checks/proofs/`.
- Modify e2e: `e2e/checks/seeded/palette-open-kinds.jsonl`, `e2e/checks/uncoverable.tsv`.
- Modify docs: `docs/architecture/{wakilkit,wakilapp,runtime,flows,state,testing}.md`, `CONTRIBUTING.md`.

**Interfaces:**
- Consumes: Task 1 (`GitStatus`) and Task 3 (`editor_changes_select` with no `pane`, which opens or
  creates an editor pane by `editorPane`'s own rule).
- Produces:
  - `layoutMigratingGitPanes(_ snapshot: LayoutSnapshot) -> LayoutSnapshot`.
  - `GitSource(status: GitStatus)`.
  - `ChangedFilesSource(status: @Sendable () async -> [GitRootState])`.
  - `gitFileRow(_ row: EditorChangesRow, in roots: [GitRootState]) -> GitFileRow?`. Delete it if
    `editorChangesFile` already covers every caller; check with grep.

- [ ] **Step 1: Write the failing migration tests**

In `LayoutPersistenceTests.swift`:

```swift
@Test func aSavedGitPaneLoadsAsAnEditorPaneOnChangesWithItsFrameAndId() throws {
    let frame = PaneFrame(x: 10, y: 20, width: 600, height: 400)
    var s = LayoutSnapshot(panes: [Pane(id: "git-1", kind: "git", title: "Git", frame: frame)], graph: SnapGraph())
    s.focusedId = "git-1"
    let out = layoutMigratingGitPanes(s)
    let p = try #require(out.panes.first)
    #expect(p.id == "git-1" && p.kind == "editor" && p.title == "Editor" && p.frame == frame)
    #expect(p.editorColumn == EditorColumnState(shown: true, view: .changes, width: 240, open: []))
    #expect(p.editorTabs == nil && out.focusedId == "git-1")
}

@Test func theMigratedColumnTakesTheLayoutsDefaultWidth() {
    var s = LayoutSnapshot(panes: [Pane(id: "g", kind: "git", title: "Git", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))],
                           graph: SnapGraph())
    s.editorColumnDefault = EditorColumnState(shown: false, view: .search, width: 310, open: [])
    #expect(layoutMigratingGitPanes(s).panes[0].editorColumn?.width == 310)
}

@Test func anyOtherUnknownKindIsStillDropped() throws {
    let s = LayoutSnapshot(panes: [Pane(id: "x", kind: "database", title: "D", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))],
                           graph: SnapGraph())
    let checked = layoutDroppingUnknownPaneKinds(layoutMigratingGitPanes(s))
    #expect(checked.snapshot.panes.isEmpty && checked.note != nil)
}

@Test func aLayoutFileWithAGitPaneComesBackAsAnEditor() throws {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let persistence = LayoutPersistence(directory: dir)
    let scope = LayoutScope(organization: "acme", project: "p", lineageRoot: nil)
    persistence.save(LayoutSnapshot(panes: [Pane(id: "git-1", kind: "git", title: "Git",
                                                 frame: PaneFrame(x: 0, y: 0, width: 500, height: 300))],
                                    graph: SnapGraph()), for: scope)
    let (loaded, note) = persistence.load(for: scope)
    #expect(loaded?.panes.first?.kind == "editor" && note == nil)
}
```

Use the file's own spelling for `LayoutPersistence`'s directory init, `save` and `testScratchRoot`.
If `save` strips unknown kinds on write, write the JSON file directly with `"kind":"git"`.

Run: `cd app && swift test --filter LayoutPersistenceTests`. Expected: build failure.

- [ ] **Step 2: The migration**

In `Layout/LayoutStore.swift`, beside `layoutDroppingUnknownPaneKinds`:

```swift
/// `snapshot` with every saved Git pane turned into an editor pane showing Changes (3b-iii, Decision
/// 40): the Git pane folded into the editor, so the pane comes back as the editor on the same list.
///
/// **The first kind migration.** Every other kind this build does not know is still dropped with a
/// note (`layoutDroppingUnknownPaneKinds`), which runs after this. Same id and frame, so the snap
/// graph, focus and maximize still name the pane (R8). No tabs: a Git pane saved none, and diff tabs
/// are never saved (R7). The column takes the layout's default width.
public func layoutMigratingGitPanes(_ snapshot: LayoutSnapshot) -> LayoutSnapshot {
    var out = snapshot
    let width = snapshot.editorColumnDefault?.width ?? EditorColumnState.initial.width
    out.panes = snapshot.panes.map { p in
        guard p.kind == "git" else { return p }
        return Pane(id: p.id, kind: "editor", title: Pane.defaultTitle(kind: "editor"), frame: p.frame,
                    density: p.density, columnWidths: p.columnWidths,
                    editorColumn: EditorColumnState(shown: true, view: .changes, width: width, open: []))
    }
    return out
}
```

Match `Pane`'s memberwise `init` labels in `Pane.swift`, keeping its defaults for `fetch` and
`terminalPath`.

In `LayoutPersistence.read`:
`let checked = layoutDroppingUnknownPaneKinds(layoutMigratingGitPanes(layoutWithoutOverlayPanes(decoded)))`.
Add a line to its comment block: *"A Git pane is migrated, not dropped (3b-iii)."*

- [ ] **Step 3: Delete the kind and everything that names it**

Work through the compiler after each deletion:
- `App/PaneKinds.swift`: remove `GitPaneKind.self`.
- `Layout/Pane.swift`: `Pane.kinds` loses `"git"`, and `defaultTitle` loses its `"git"` case.
- `WindowModel.swift`:
  - Remove: `git(_:)`; `refreshGitPanes`; `refreshUnreadGitPanes`; `openGitAndSelect`;
    `waitForFirstGitStatus`; `paletteGitPanes`; the `.openGitAndSelect` arm of the palette switch.
  - `syncGitWatcher`: `showsGit` is only `EditorPaneKind`. In `.unchanged`, nothing remains to read, so
    the case is `break`. In `.started`, after `gitStatus?.refresh()`, dispatch
    `editor_refresh(what: git)` to every editor pane (the loop from `gitRootChanged`; lift it into
    `refreshEditorGit(root: String?)` and call it from both).
  - `gitRootChanged` becomes: mark loading in the mirror, `await gitStatus?.refresh(only: root)`,
    `await refreshEditorGit(root: root)`.
  - `palettePaneSummaries` drops `gitRoots:`.
  - `ChangedFilesSource` is built as `ChangedFilesSource(status: { [weak self] in await self?.paletteGitStatus() ?? [] })`,
    where:

```swift
    /// ⌘P's changed files: the window's status while an editor pane keeps it live, else a read made
    /// for the palette alone (as before, when no Git pane was open).
    private func paletteGitStatus() async -> [GitRootState] {
        if !gitRoots.isEmpty { return gitRoots }
        return await paletteGitStatusWithoutPane()
    }
```

- `Command/PaletteSources.swift`:
  - `ChangedFilesSource` keeps one closure, `status`. Each row is
    `.dispatch(action: "editor_changes_select", params: .object(["root": …, "path": …, "group": …]))`
    with no `pane`, so `editorPane` picks the focused or first editor pane, or opens one.
  - Delete the `seen` de-duplication across panes; there is one list now.
  - `kindLabel` stays `"git"`, since it names what the row is.
  - `PaneSummary.init(pane:apiEntry:gitRoots:)` loses `gitRoots` and its `"git"` case.
  - `paneKindOrder` and the two `case "git"` labels go.
- `Command/PaletteEntry.swift`: delete `case openGitAndSelect(root:path:group:)`.
- `Command/CommandCatalog.swift`: delete the `git.refresh`, `git.unfold` and `close("git")` entries.
- `Command/PaletteSearch.swift`: delete the `"git": ["git"]` synonym line.
- `Git/GitSource.swift`:
  - It reads the status: `init(status: GitStatus)`; the loop is `for root in await status.roots`.
  - The doc says it offers the names while the window keeps the status, that is, while an editor pane
    is open.
  - `AppWiring` passes `GitSource(status: gitStatus)`.
- `AppWiring.swift`: delete the `registerGitActions` call. `gitRoots` (the `GitRootsSource`) and
  `gitStatus` stay, and the editor actions use them.
- `WakilApp/Canvas.swift`: delete the `case "git":` arm and fix the comment that lists five arms.
  `Landing.swift`: delete `case "git": return "Git"`.
- `WakilApp/main.swift`: delete the `--probe-monaco` block. In `docs/architecture/wakilapp.md`, delete
  its row.

- [ ] **Step 4: Tests that named the kind**

- **Delete** `GitActionsTests.swift`, `GitPaneSnapshotTests.swift` and `GitNavigationTests.swift`.
  Their kept rules live in `GitStatusTests` (Task 1) and `EditorChangesTests` (Task 2).
- `GitPaneLinesTests.swift`: keep the tests of the functions that survive; delete the rest (spine,
  folded style, positions, headers, keys).
- `GitTestSupport.swift`: delete `openGitPane()`. `FakeGit` stays.
- `WindowModelGitTests.swift`:
  - The tests that opened `git` panes open `editor` panes. The window's builder registers the editor
    actions with the `GitStatus` (as `WindowModelEditorTests` does) instead of `registerGitActions`.
  - `oneReadPerRootPerWakeWhateverTheNumberOfPanes` opens two editor panes and asserts
    `model.gitRoots`.
  - Delete the tests of git-pane selection (`git_select` from the surface).
- `GitSourceTests.swift`: build `GitSource(status:)` over a `GitStatus` that has read a `FakeGit`. Assert
  the same names, plus none before a read.
- `PaneKindRestoreTests.swift`: delete the git test.
- `PaneKindClassificationTests.swift`: `rerun == ["db"]`; delete the `git` line.
- `PaneKindStorageTests.swift`: delete the two `"git"` expectations, or point them at `"db"`, whichever
  keeps the test's point.
- `AppWiringTests.swift`:
  - Remove the five `git_*` names from the action list, and add `editor_changes_select`,
    `editor_changes_step`, `editor_changes_collapse`, `editor_changes_expand` and `editor_open_file`.
  - Delete the `git_refresh` refusal test; `EditorChangesActionsTests` has its equivalent.
- `WindowModelPaletteTests.swift`:
  - Remove the git registration at lines ~156 and the two name lists (~981, ~1009), adding the new
    editor names to them.
  - The tests of opening a git pane from ⌘P and of `openGitAndSelect` become one test: choosing a
    changed file with no editor pane opens an editor pane with that diff tab. Expect `"editor_changes_select"`
    in the journal with outcome `ok`.
- `PaletteSourcesTests.swift`:
  - `ChangedFilesSource` is built from a status closure.
  - The action is `.dispatch(action: "editor_changes_select", params: .object(["root": …, "path": …, "group": …]))`.
  - The `p3` git pane in the summaries test becomes another kind.
- `PaletteSearchTests.swift`: drop `("git", "git")` and the `newpane:git` / `g1` git pane cases.
- `CommandCatalogTests.swift`: the git context's tests use another kind's commands (`db`).
- `PaletteModelTests.swift`: `focusedPane: FocusedPane(id: "git-1", kind: "git")` becomes a `db` pane.
  The two `git_refresh` expectations become that kind's first catalog command.
- `WindowModelEditorTests.swift`: the three `openPane(kind: "git")` calls (used only to move focus)
  become `openPane(kind: "api")`.

Run: `make app-test`. Expected: green.

- [ ] **Step 5: e2e — remove what tests a deleted kind (R14)**

```bash
git rm e2e/checks/seeded/3a-i-git-list.jsonl e2e/checks/seeded/3a-i-git-drill.jsonl \
       e2e/checks/seeded/3a-i-git-keys.jsonl e2e/checks/seeded/3a-i-git-live.jsonl \
       e2e/checks/seeded/3a-i-git-press.jsonl e2e/checks/agent/3a-i-git-voice-hint.jsonl \
       e2e/checks/seeded/palette-new-git-parity.jsonl
ls e2e/checks/proofs | grep -E '^(3a-i-git|palette-new-git-parity)' | sed 's#^#e2e/checks/proofs/#' | xargs git rm
```

- `palette-open-kinds.jsonl`: delete the line that expects `git-4` to be a git pane, and the open
  that made it. Renumber any later pane ids it asserts.
- `uncoverable.tsv`: delete the `git_step`, `git_unfold` and `git_fold` rows and every `git.*`
  identifier row (`git.pane`, `git.root:<…>`, `git.rootError:<…>`, `git.diffHeader`, `git.diffBanner`,
  `git.diffError`, `git.diff`, `git.loading`, and any other `git.` row).
- Check that nothing else names them: `grep -rn 'git-1\|"git_\|git\.row\|git\.mark' e2e/`. Expected:
  only Go code running the `git` binary.

The Changes rewrites and the new checks are the Cover rung's (Task 8 hands the list over).

- [ ] **Step 6: The architecture docs**

- `docs/architecture/wakilkit.md`:
  - The Git section lists `GitStatus.swift` (the window's status, `GitStatus`, the moved types),
    `GitPaneLines.swift` (the text helpers the Changes view draws), `GitSource.swift`,
    `GitWatcher.swift` and `GitRootWatcher.swift`.
  - The Editor section gains `EditorChanges.swift` and `EditorDiff.swift`. `EditorActions.swift`'s
    bullet gains *"3b-iii adds `editor_changes_select`, `editor_changes_step`, `editor_changes_collapse`,
    `editor_changes_expand`, `editor_open_file`, and `editor_refresh`'s `what`"*.
  - The pane-kinds table loses its `git` row.
  - The layering paragraph gains `Editor -> Git`.
- `docs/architecture/wakilapp.md`: delete the `git` row and the `--probe-monaco` row. The editor row
  names `MonacoEditorRenderer.swift` (one page: code editor and diff editor).
- `runtime.md`: item 5 loses `registerGitActions` and gains *"`GitStatus` (`Git/GitStatus.swift`),
  built over the git client and `GitRootsSource`, handed to the editor actions, `GitSource` and the
  window"*. Item 6's `GitSource` reads it.
- `flows.md` and `state.md`: `syncGitWatcher()` now watches while an editor pane is open. `state.md`
  lists `WindowModel.gitRoots` as memory-only, reset on an org switch.
- `testing.md`: the git suites named become `GitStatusTests`, `EditorChangesTests`,
  `EditorChangesActionsTests` and `EditorDiffTabsTests`.
- `CONTRIBUTING.md`, *A new pane kind*: Git is no longer the smallest example. Say *"Api
  (`Api/ApiPaneKind.swift`, `Api/PaneStore+Api.swift`)"*, after checking those file names exist. The
  where-does-code-go table's example `registerGitActions` becomes `registerEditorActions` in
  `Editor/EditorActions.swift`.

`TestArchitectureDocsCoverEveryFolderAndBinary` must still pass. Run `make test`.

- [ ] **Step 7: The whole PR**

Run: `make build && make test && make app-test`. Expected: green.

Run the app with a layout saved before this PR that holds a Git pane. Expect the pane to come back as
an editor in the same place, its column on Changes. ⌘P's changed files open diff tabs.

- [ ] **Step 8: Commit and open PR 3**

```bash
git add -A app e2e docs CONTRIBUTING.md
git commit -m "3b-iii PR 3 (3/3): the Git pane kind is deleted and saved Git panes open as the editor on Changes"
gh stack submit
```

The PR body lists:
- the deleted checks (R14);
- `--probe-monaco` (R3);
- that Compare now shares the pane's page (R2).

---
### Task 6: Gutter marks — `editorHunks`, the baseline, the decorations (PR 4)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorHunks.swift`
- Modify:
  - `app/Sources/WakilKit/Editor/EditorSnapshot.swift` (`baseline`);
  - `app/Sources/WakilKit/Editor/EditorActions.swift` (fetch on open, restore and wake; kept across a
    reload; `editorAfterDiskRead`);
  - `app/Sources/WakilKit/Editor/EditorPaneKind.swift` (`hunks`);
  - `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `app/Sources/WakilApp/monaco-host.html`,
    `app/Sources/WakilApp/EditorPane.swift`.
- Test: `app/Tests/WakilKitTests/EditorHunksTests.swift` (new), `app/Tests/WakilKitTests/EditorBaselineTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 (`GitStatus.git`) and Task 3 (`refreshGit`, `openFile`).
- Produces:
  - `EditorTab.baseline: String?`, the index text, or nil for no marks.
  - `public struct EditorHunk { kind: EditorHunk.Kind (.added/.changed/.deleted); newStart: Int; newCount: Int; oldLines: [String] }`.
  - `editorHunks(base: String, text: String) -> [EditorHunk]` and `editorHunkLines(_:) -> [String]`.
  - `public struct EditorGutterMark { kind: EditorGutterMark.Kind (.added/.changed/.deletedBelow/.deletedAbove); start: Int; end: Int }`.
  - `editorGutterMarks(_:) -> [EditorGutterMark]` and `editorHunkIndex(at:in:) -> Int?`.
  - `editorRevertEdit(_ hunk: EditorHunk, text: String) -> (range: EditorRange, text: String)`, used
    by Task 7 and tested here.
  - `MonacoEditorRenderer.setMarks(key:marks:)` and `MonacoEditorRenderer.onMark: ((String, Int) -> Void)?`.

- [ ] **Step 1: Write the failing table**

`app/Tests/WakilKitTests/EditorHunksTests.swift`:

```swift
import Testing
@testable import WakilKit

private struct Case: Sendable, CustomStringConvertible {
    let name: String, base: String, text: String, hunks: [EditorHunk]
    var description: String { name }
}
private func h(_ k: EditorHunk.Kind, _ start: Int, _ count: Int, _ old: [String] = []) -> EditorHunk {
    EditorHunk(kind: k, newStart: start, newCount: count, oldLines: old)
}

private let cases: [Case] = [
    Case(name: "an added line", base: "a\nc\n", text: "a\nb\nc\n", hunks: [h(.added, 2, 1)]),
    Case(name: "a changed line", base: "a\nb\nc\n", text: "a\nB\nc\n", hunks: [h(.changed, 2, 1, ["b"])]),
    Case(name: "a deleted line", base: "a\nb\nc\n", text: "a\nc\n", hunks: [h(.deleted, 2, 0, ["b"])]),
    Case(name: "a deletion at the end", base: "a\nb\n", text: "a\n", hunks: [h(.deleted, 2, 0, ["b"])]),
    Case(name: "a deletion at the start", base: "a\nb\n", text: "b\n", hunks: [h(.deleted, 1, 0, ["a"])]),
    Case(name: "a missing final newline (R9)", base: "a\nb\n", text: "a\nb", hunks: []),
    Case(name: "CRLF", base: "a\r\nb\r\n", text: "a\r\nB\r\n", hunks: [h(.changed, 2, 1, ["b\r"])]),
    Case(name: "an empty base", base: "", text: "x\ny\n", hunks: [h(.added, 1, 2)]),
    Case(name: "an empty text", base: "x\ny\n", text: "", hunks: [h(.deleted, 1, 0, ["x", "y"])]),
    Case(name: "identical texts", base: "a\nb\n", text: "a\nb\n", hunks: []),
    Case(name: "two hunks, one unchanged line apart", base: "a\nb\nc\n", text: "A\nb\nC\nd\n",
         hunks: [h(.changed, 1, 1, ["a"]), h(.changed, 3, 2, ["c"])]),
    Case(name: "added at the end with no final newline", base: "a", text: "a\nb", hunks: [h(.added, 2, 1)]),
    Case(name: "deleted at the end with no final newline", base: "a\nb", text: "a", hunks: [h(.deleted, 2, 0, ["b"])]),
]

@Suite struct EditorHunksTests {
    @Test(arguments: cases) func hunksAreGroupedAsTheSpecReadsThem(_ c: Case) {
        #expect(editorHunks(base: c.base, text: c.text) == c.hunks)
    }

    // Review Focus 3: Revert puts the exact base text back — every hunk, last first.
    @Test(arguments: cases) func revertRestoresTheBaseText(_ c: Case) {
        guard !c.hunks.isEmpty else { return }
        var text = c.text
        for hunk in editorHunks(base: c.base, text: c.text).reversed() {
            let e = editorRevertEdit(hunk, text: text)
            text = editorReplacing(text, e.range, with: e.text)
        }
        #expect(text == c.base)
    }

    @Test func marksSitOnTheirLinesAndADeletionBetweenTwo() {
        let hunks = [h(.added, 2, 2), h(.changed, 5, 1, ["x"]), h(.deleted, 7, 0, ["y"]), h(.deleted, 1, 0, ["z"])]
        #expect(editorGutterMarks(hunks) == [
            EditorGutterMark(kind: .added, start: 2, end: 3), EditorGutterMark(kind: .changed, start: 5, end: 5),
            EditorGutterMark(kind: .deletedBelow, start: 6, end: 6), EditorGutterMark(kind: .deletedAbove, start: 1, end: 1)])
    }

    @Test func aLineFindsTheHunkWhoseMarkItCarries() {
        let hunks = [h(.added, 2, 2), h(.deleted, 7, 0, ["y"])]
        #expect(editorHunkIndex(at: 3, in: hunks) == 0)
        #expect(editorHunkIndex(at: 6, in: hunks) == 1, "a deletion's triangle sits on the line above it")
        #expect(editorHunkIndex(at: 5, in: hunks) == nil)
    }
}
```

Add `extension EditorHunk: CustomTestStringConvertible` only if the arguments need it to compile.

Run: `cd app && swift test --filter EditorHunksTests`. Expected: build failure.

- [ ] **Step 2: `Editor/EditorHunks.swift`**

```swift
import Foundation

// The gutter's change marks, the peek and Revert (3b-iii), pure. A file tab's text is compared with
// its baseline — the file's index text (`git_show` rev index) — line by line with Swift's
// `CollectionDifference`. Nothing is diffed in JavaScript and no Go tool is involved.

/// A text's lines as hunks compare them: split at "\n", without the empty line after a final newline,
/// so a missing final newline is no change (R9). "" has no lines.
public func editorHunkLines(_ t: String) -> [String] {
    if t.isEmpty { return [] }
    var lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if t.hasSuffix("\n") { lines.removeLast() }
    return lines
}

/// One change between a baseline and a text: lines added, changed (old and new), or deleted.
public struct EditorHunk: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case added, changed, deleted }
    public var kind: Kind
    /// The first new line, 1-based. For `deleted`, the line the removed lines sat before — one past
    /// the text's last line when they were at the end.
    public var newStart: Int
    /// How many new lines; 0 for `deleted`.
    public var newCount: Int
    /// The baseline's lines the hunk replaced; empty for `added`. All Revert needs.
    public var oldLines: [String]

    public init(kind: Kind, newStart: Int, newCount: Int, oldLines: [String]) {
        self.kind = kind
        self.newStart = newStart
        self.newCount = newCount
        self.oldLines = oldLines
    }
}

/// `text`'s hunks against `base`, in line order. Adjacent removals and insertions are one hunk.
public func editorHunks(base: String, text: String) -> [EditorHunk] {
    let old = editorHunkLines(base), new = editorHunkLines(text)
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in new.difference(from: old) {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    var hunks: [EditorHunk] = []
    var i = 0, j = 0
    while i < old.count || j < new.count {
        guard removed.contains(i) || inserted.contains(j) else {
            i += 1
            j += 1
            continue
        }
        let start = j
        var gone: [String] = []
        while removed.contains(i) || inserted.contains(j) {
            while removed.contains(i) { gone.append(old[i]); i += 1 }
            while inserted.contains(j) { j += 1 }
        }
        let count = j - start
        let kind: EditorHunk.Kind = gone.isEmpty ? .added : (count == 0 ? .deleted : .changed)
        hunks.append(EditorHunk(kind: kind, newStart: start + 1, newCount: count, oldLines: gone))
    }
    return hunks
}

/// One gutter mark: a bar beside lines `start`…`end`, or a deletion's triangle on one line — below
/// it, or above line 1 when the deleted lines were at the very start.
public struct EditorGutterMark: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case added, changed, deletedBelow, deletedAbove }
    public var kind: Kind
    public var start: Int
    public var end: Int
    public init(kind: Kind, start: Int, end: Int) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// The marks the gutter draws, one per hunk, in hunk order (so a mark's index is its hunk's).
public func editorGutterMarks(_ hunks: [EditorHunk]) -> [EditorGutterMark] {
    hunks.map { h in
        switch h.kind {
        case .added: EditorGutterMark(kind: .added, start: h.newStart, end: h.newStart + h.newCount - 1)
        case .changed: EditorGutterMark(kind: .changed, start: h.newStart, end: h.newStart + h.newCount - 1)
        case .deleted:
            h.newStart > 1 ? EditorGutterMark(kind: .deletedBelow, start: h.newStart - 1, end: h.newStart - 1)
                           : EditorGutterMark(kind: .deletedAbove, start: 1, end: 1)
        }
    }
}

/// The hunk whose mark is on `line`, or nil.
public func editorHunkIndex(at line: Int, in hunks: [EditorHunk]) -> Int? {
    editorGutterMarks(hunks).firstIndex { $0.start <= line && line <= $0.end }
}

/// The buffer edit that puts `hunk` back to its baseline lines, against `text` as it is (Revert):
/// a range and what replaces it, for `editor_replace_range`. Positions are 1-based, UTF-16 columns,
/// over `text`'s raw lines (the line after a final newline included).
public func editorRevertEdit(_ hunk: EditorHunk, text: String) -> (range: EditorRange, text: String) {
    let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    func head(_ line: Int) -> EditorPosition { EditorPosition(line: line, column: 1) }
    func tail(_ line: Int) -> EditorPosition { EditorPosition(line: line, column: raw[line - 1].utf16.count + 1) }
    let s = hunk.newStart, e = hunk.newStart + hunk.newCount - 1
    let old = hunk.oldLines.joined(separator: "\n")
    switch hunk.kind {
    case .changed:
        return (EditorRange(start: head(s), end: tail(e)), old)
    case .added:
        if e < raw.count { return (EditorRange(start: head(s), end: head(e + 1)), "") }      // with the newline after
        if s > 1 { return (EditorRange(start: tail(s - 1), end: tail(e)), "") }            // the newline before
        return (EditorRange(start: head(1), end: tail(e)), "")
    case .deleted:
        if s <= raw.count { return (EditorRange(start: head(s), end: head(s)), old + "\n") }
        let last = raw.count
        return (EditorRange(start: tail(last), end: tail(last)), "\n" + old)              // after a last line with no newline
    }
}
```

Run: `cd app && swift test --filter EditorHunksTests`. Expected: PASS. If a revert row fails, fix
`editorRevertEdit`, not the table: the table states the spec.

- [ ] **Step 3: Write the failing baseline tests**

`app/Tests/WakilKitTests/EditorBaselineTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Suite struct EditorBaselineTests {
    @Test func anOpenedTrackedFileGetsItsIndexTextAsItsBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        #expect(await f.snapshot().tabs[0].baseline == "old\n")
        #expect(await f.git.calls.contains("git_show /p/api b.go"))
    }

    @Test func aFileGitCannotShowFromTheIndexHasNoBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/n", "untracked\n")
        await f.git.set(showError: "/p/api|n|index", "fatal: path 'n' exists on disk, but not in the index")
        try await f.dispatch("editor_open", ["path": .string("/p/api/n")])
        #expect(await f.snapshot().tabs[0].baseline == nil)
    }

    @Test func aReadOnlyTabAndAScratchTabFetchNoBaseline() async throws {
        let f = try await changesFixture()
        await f.files.putOverCap("/p/api/big.go", size: 3_000_000)
        try await f.dispatch("editor_open", ["path": .string("/p/api/big.go")])
        try await f.dispatch("editor_new_scratch")
        #expect(await !f.git.calls.contains { $0.contains("big.go") })
        #expect(await f.snapshot().tabs.allSatisfy { $0.baseline == nil })
    }

    @Test func aGitWakeRefetchesTheBaselineOfTabsUnderItsRoot() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.git.set(show: "/p/api|b.go|index", "new\n")          // staged in a terminal
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")])
        #expect(await f.snapshot().tabs[0].baseline == "new\n")
    }

    @Test func aDiskReloadKeepsTheBaseline() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|index", "old\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.files.put("/p/api/b.go", "newer\n")
        try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("files")])
        try await f.dispatch("editor_reload", ["path": .string("/p/api/b.go")])
        #expect(await f.snapshot().tabs[0].baseline == "old\n")
    }

    // Review Focus 4.
    @Test func aBaselineLandingAfterItsTabClosedWritesNothing() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "new\n")
        await f.git.set(show: "/p/api|b.go|worktree", "")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        await f.git.setSlowShow(true)
        let wake = Task { try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "what": .string("git")]) }
        while await f.git.calls.filter({ $0 == "git_show /p/api b.go" }).count < 2 { await Task.yield() }
        try await f.dispatch("editor_close", ["path": .string("/p/api/b.go")])
        await f.git.release()
        _ = try await wake.value
        #expect(await f.snapshot().tabs.isEmpty)
    }

    @Test func readPaneListsTheActiveTabsHunks() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "a\nB\nc\n")
        await f.git.set(show: "/p/api|b.go|index", "a\nb\nc\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["hunks"] == .array([.object(["kind": .string("changed"), "line": .number(2), "count": .number(1)])]))
    }
}
```

Run: `cd app && swift test --filter EditorBaselineTests`. Expected: build failure.

- [ ] **Step 4: The baseline in the store and the actions**

- `EditorTab` gains `public var baseline: String?`, documented as *"The file's index text (3b-iii),
  which its gutter marks compare against. nil means no marks: untracked, outside a repository,
  scratch, read-only, or not fetched yet."* It joins `init` with default `nil`.
- `editorAfterDiskRead(_:read:)` carries `baseline` (and, from Task 7, `peek`) over from the old tab,
  like the other fields it keeps. `editor_reload` sets `fresh.baseline = s.tabs[i].baseline`.
- In `registerEditorActions`, beside `fetchDiff`:

```swift
    /// The index text of `path` (in `root`) into every tab of `pane` showing it, or nil there when git
    /// cannot show it (untracked, not a repository, binary, cut at the cap). A tab gone or read-only
    /// by the time it lands is left alone.
    @Sendable func fetchBaseline(_ pane: String, path: String, root: String) async {
        guard let git = gitStatus?.git, path.hasPrefix(root + "/") else { return }
        let rel = String(path.dropFirst(root.count + 1))
        let base: String?
        switch try? await filesTool(git, "git_show", ["root": .string(root), "path": .string(rel), "rev": .string("index")]) {
        case .ok(let o)? where o["binary"] != .bool(true) && o["truncated"] != .bool(true):
            if case .string(let t)? = o["text"] { base = t } else { base = nil }
        default:
            base = nil
        }
        if Task.isCancelled { return }
        await panes.updateEditor(paneId: pane) { s in
            for i in s.tabs.indices where s.tabs[i].path == path && !s.tabs[i].readOnly { s.tabs[i].baseline = base }
        }
    }
```

- `openFile` (Task 3): after a tab is newly read and written (the `!focused` branch), if the read tab
  is not read-only, `await fetchBaseline(pane, path: path, root: tab.subject's root)`. Get the root
  from `confine`'s result, which `read` already resolved. Return it with the tab, or call
  `confine(path, action:)` again.
- `editor_restore`: after the `updateEditor` that adds the restored tabs, call `fetchBaseline` for each
  added file tab that is not read-only.
- `refreshGit` gains the baselines, after the diff tabs:

```swift
        let fileTabs: [(path: String, root: String)] = await panes.editorSnapshot(paneId: pane).tabs.compactMap { t in
            guard case .file(let p, let r) = t.subject, root == nil || r == root, !t.readOnly else { return nil }
            return (p, r)
        }
        await withTaskGroup(of: Void.self) { group in
            for t in fileTabs { group.addTask { await fetchBaseline(pane, path: t.path, root: t.root) } }
        }
```

- `EditorPaneKind.readPane` gains `hunks`, the active file tab's, always present:

```swift
        o["hunks"] = tab.flatMap { t in t.baseline.map { base in
            .array(editorHunks(base: base, text: t.text).map { h in
                .object(["kind": .string(h.kind.rawValue), "line": .number(Double(h.newStart)),
                         "count": .number(Double(h.newCount))]) }) } } ?? .null
```

Run: `cd app && swift test --filter 'EditorBaselineTests|EditorHunksTests|EditorActionsTests|EditorReadPaneTests'`.
Expected: PASS.

- [ ] **Step 5: Draw the marks**

`monaco-host.html`:
- The code editor's options gain `lineDecorationsWidth: 10`.
- The `<style>` gains the marks. Green and amber are §5's; the triangle is the muted text tone; there
  is no red.

```css
.wakil-mark-added{border-left:3px solid #8be0c8;margin-left:4px}
.wakil-mark-changed{border-left:3px solid #e8b45a;margin-left:4px}
.wakil-mark-deletedBelow,.wakil-mark-deletedAbove{position:relative}
.wakil-mark-deletedBelow::after,.wakil-mark-deletedAbove::after{content:'';position:absolute;left:3px;border:4px solid transparent;border-left-color:rgba(232,236,246,.45)}
.wakil-mark-deletedBelow::after{bottom:-4px}
.wakil-mark-deletedAbove::after{top:-4px}
```

- Inside the editor code:

```js
      // 3b-iii: the gutter's change marks, as line decorations per model (WakilKit computes them).
      const marks = {};   // key -> decoration ids
      window.wakilSetMarks = function (key, list) {
        const m = models[key]; if (!m) return;
        marks[key] = m.deltaDecorations(marks[key] || [], list.map(function (x) {
          return { range: new monaco.Range(x.start, 1, x.end, 1),
                   options: { isWholeLine: true, linesDecorationsClassName: 'wakil-mark-' + x.kind } };
        }));
      };
      // A click on a mark opens the peek on its hunk (editor_peek).
      ed.onMouseDown(function (e) {
        if (!current || !e.target || e.target.type !== monaco.editor.MouseTargetType.GUTTER_LINE_DECORATIONS) return;
        post({ type: 'mark', key: current, line: e.target.position.lineNumber });
      });
```

- `wakilDispose` also does `delete marks[key];`.

`MonacoEditorRenderer.swift`:

```swift
    /// A mark clicked in `key`'s gutter, on `line`.
    var onMark: ((String, Int) -> Void)?

    func setMarks(key: String, marks: [EditorGutterMark]) {
        let list = marks.map { "{kind:\(Self.jsString($0.kind.rawValue)),start:\($0.start),end:\($0.end)}" }
        run("wakilSetMarks(\(Self.jsString(key)),[\(list.joined(separator: ","))])")
    }
```

In `receive`, add
`case "mark": if let key = body["key"] as? String, let line = Self.int(body["line"]) { onMark?(key, line) }`.

`EditorHost` computes the marks off the snapshot, debounced (spec: *"debounced like the tree's
reads"*):

```swift
    /// The marks last sent, per key: an unchanged set is not sent again.
    @ObservationIgnored private var marksSent: [String: [EditorGutterMark]] = [:]
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    /// A mark clicked: (tab subject, line).
    @ObservationIgnored var markClicked: ((EditorTabSubject, Int) -> Void)?

    /// The active file tab's marks, 150 ms after its text or baseline last changed. No baseline, no marks.
    private func scheduleMarks(_ snapshot: EditorSnapshot) {
        marksTask?.cancel()
        guard let i = snapshot.active, i < snapshot.tabs.count, snapshot.tabs[i].diffState == nil else { return }
        let t = snapshot.tabs[i], key = editorTabKey(t)
        let base = t.readOnly ? nil : t.baseline, text = t.text
        marksTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let renderer = self.renderer else { return }
            let marks = base.map { editorGutterMarks(editorHunks(base: $0, text: text)) } ?? []
            guard self.marksSent[key] != marks else { return }
            self.marksSent[key] = marks
            renderer.setMarks(key: key, marks: marks)
        }
    }
```

- At the end of `apply(_:)`, call `scheduleMarks(shown)`.
- After computing `steps`, add `for case .dispose(let k) in steps { marksSent[k] = nil }`.
- In `start()`:
  `made.onMark = { [weak self] key, line in guard let self, let s = self.subjects[key] else { return }; self.markClicked?(s, line) }`.
  Task 7 hands `markClicked` its dispatch.

- [ ] **Step 6: Run and look**

Run: `make app-test`. Expected: green.

Open `e2e-api/app.txt` from the fixture. Line 2 shows an amber bar (staged "line two, staged" against
the index) and line 3 a green bar. Type on line 1, and an amber bar appears within a moment. Delete
line 3, and the muted triangle sits under line 2. Stage in a terminal, and the marks go.

- [ ] **Step 7: Commit and open PR 4**

```bash
git switch -c yehia-khalil/3b-iii-4-gutter
git add app/Sources app/Tests
git commit -m "3b-iii PR 4: gutter change marks against the index, from the buffer, refetched on a git wake"
gh stack submit
```

---

### Task 7: The peek — open, step, Esc, Revert (PR 5)

**Files:**
- Modify:
  - `app/Sources/WakilKit/Editor/EditorSnapshot.swift` (`peek`);
  - `app/Sources/WakilKit/Editor/EditorHunks.swift` (the peek view, title and Revert's dispatch);
  - `app/Sources/WakilKit/Editor/EditorActions.swift` (three actions; `editor_replace_range` clamps);
  - `app/Sources/WakilKit/Editor/PaneStore+Editor.swift` (typing closes it);
  - `app/Sources/WakilKit/Editor/EditorPaneKind.swift` (`peek`);
  - `app/Sources/WakilKit/Editor/EditorRenderer.swift` (the step);
  - `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `app/Sources/WakilApp/monaco-host.html`,
    `app/Sources/WakilApp/EditorPane.swift`.
- Test: `app/Tests/WakilKitTests/EditorPeekTests.swift` (new), `app/Tests/WakilKitTests/EditorRendererTests.swift`

**Interfaces:**
- Consumes (Task 6): `editorHunks`, `editorGutterMarks`, `editorHunkIndex`, `editorRevertEdit`, `EditorTab.baseline`.
- Produces:
  - `EditorTab.peek: Int?`.
  - `public struct EditorPeekView { index, count, afterLine: Int; title: String; old, new: [String] }` and
    `editorPeekView(_ tab: EditorTab) -> EditorPeekView?`.
  - `editorPeekRevert(_ s: EditorSnapshot) -> (path: String, range: EditorRange, text: String)?`.
  - `editorRangeParam(_ r: EditorRange) -> JSONValue`.
  - `EditorRenderStep.peek(key: String, EditorPeekView?)`, `EditorRenderer.showPeek(key:_:)` and
    `EditorRendered.peek`.
  - The actions `editor_peek`, `editor_peek_step` and `editor_peek_close`.
  - `EditorActionError.noMarks(action:)`, `.noChange(line:)` and `.noPeek(action:)`.

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/EditorPeekTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// b.go: base "a\nb\nc\nd\ne\n", text with line 2 changed and line 4 deleted: two hunks.
private func peekFixture() async throws -> EditorFixture {
    let f = try await changesFixture()
    await f.files.put("/p/api/b.go", "a\nB\nc\ne\n")
    await f.git.set(show: "/p/api|b.go|index", "a\nb\nc\nd\ne\n")
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    return f
}

@Suite struct EditorPeekTests {
    @Test func aMarksLineOpensThePeekOnItsHunkAndMovesTheCursorThere() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(3)])     // the deletion's triangle, under line 3
        let t = await f.snapshot().tabs[0]
        #expect(t.peek == 1 && t.cursor.line == 3)
        let v = try #require(editorPeekView(t))
        #expect(v.title == "2 of 2 changes" && v.old == ["d"] && v.new.isEmpty && v.afterLine == 3)
    }

    @Test func stepClampsAtEitherEnd() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        try await f.dispatch("editor_peek_step", ["delta": .integer(5)])
        #expect(await f.snapshot().tabs[0].peek == 1)
        try await f.dispatch("editor_peek_step", ["delta": .integer(-5)])
        #expect(await f.snapshot().tabs[0].peek == 0)
    }

    @Test func closeLeavesTheCursorWhereItWas() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        let cursor = await f.snapshot().tabs[0].cursor
        try await f.dispatch("editor_peek_close")
        let t = await f.snapshot().tabs[0]
        #expect(t.peek == nil && t.cursor == cursor)
    }

    @Test func typingClosesThePeekAndKeepsTheMarks() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "a\nB\nc\ne\nf\n", basis: 0)
        let t = await f.snapshot().tabs[0]
        #expect(t.peek == nil && t.baseline != nil)
    }

    // Rule 1: Revert is a buffer edit — dirty, unsaved, undoable — and asks nothing. R12: the peek moves on.
    @Test func revertDispatchesTheHunksOldLinesAndThePeekMovesToTheNextHunk() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        let r = try #require(editorPeekRevert(await f.snapshot()))
        #expect(r.path == "/p/api/b.go" && r.text == "b")
        try await f.dispatch("editor_replace_range", ["path": .string(r.path), "range": editorRangeParam(r.range),
                                                      "text": .string(r.text)])
        let t = await f.snapshot().tabs[0]
        #expect(t.text == "a\nb\nc\ne\n" && t.dirty)
        #expect(await f.files.text(of: "/p/api/b.go") == "a\nB\nc\ne\n", "nothing is saved until ⌘S")
        #expect(t.peek == 0, "the deletion, the next hunk, now holds index 0")
        #expect(editorPeekView(t)?.old == ["d"])
    }

    @Test func revertingTheLastHunkClosesThePeek() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "X\n")
        await f.git.set(show: "/p/api|b.go|index", "x\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        try await f.dispatch("editor_peek", ["line": .integer(1)])
        let r = try #require(editorPeekRevert(await f.snapshot()))
        try await f.dispatch("editor_replace_range", ["path": .string(r.path), "range": editorRangeParam(r.range),
                                                      "text": .string(r.text)])
        #expect(await f.snapshot().tabs[0].peek == nil)
    }

    @Test func aLineWithNoMarkIsRefusedNamingIt() async throws {
        let f = try await peekFixture()
        await #expect(throws: EditorActionError.noChange(line: 1)) { try await f.dispatch("editor_peek", ["line": .integer(1)]) }
    }

    @Test func aTabWithNoMarksIsRefused() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_new_scratch")
        await #expect(throws: EditorActionError.noMarks(action: "editor_peek")) {
            try await f.dispatch("editor_peek", ["line": .integer(1)])
        }
    }

    @Test func stepWithNoPeekOpenIsRefused() async throws {
        let f = try await peekFixture()
        await #expect(throws: EditorActionError.noPeek(action: "editor_peek_step")) {
            try await f.dispatch("editor_peek_step", ["delta": .integer(1)])
        }
    }

    @Test func readPaneSaysWhichChangeThePeekShows() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["peek"] == .object(["index": .number(0), "count": .number(2), "line": .number(2)]))
    }
}
```

In `EditorRendererTests.swift`:

```swift
@Test func anOpenPeekIsAStepAndShowingAnotherTabDropsIt() {
    var t = EditorTab.file(path: "/p/a.go", root: "/p", text: "a\nB\n", mtime: 1, language: "go")
    t.baseline = "a\nb\n"
    t.peek = 0
    let s = EditorSnapshot(tabs: [t], active: 0)
    let steps = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    #expect(steps.contains(.peek(key: "file:/p/a.go", editorPeekView(t))))
    let r = editorRenderedAfter(steps, rendered: [:], snapshot: s)
    #expect(!editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: s).contains { if case .peek = $0 { true } else { false } })
    var closed = s; closed.tabs[0].peek = nil
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: closed) == [.peek(key: "file:/p/a.go", nil)])
}
```

Run: `cd app && swift test --filter 'EditorPeekTests|EditorRendererTests'`. Expected: build failure.

- [ ] **Step 2: The model**

- `EditorTab` gains `public var peek: Int?`, documented as *"The hunk the peek shows (3b-iii); nil
  when closed."* It joins `init` with default `nil`. `editorAfterDiskRead` keeps it, clamped as below.
- In `EditorHunks.swift`:

```swift
/// What the peek draws for a tab: its hunk's old lines over its new ones, under line `afterLine`
/// (0: above the first line), and its header's title — `2 of 5 changes`.
public struct EditorPeekView: Sendable, Equatable {
    public var index: Int
    public var count: Int
    public var afterLine: Int
    public var title: String
    public var old: [String]
    public var new: [String]
}

public func editorPeekView(_ tab: EditorTab) -> EditorPeekView? {
    guard let i = tab.peek, let base = tab.baseline else { return nil }
    let hunks = editorHunks(base: base, text: tab.text)
    guard hunks.indices.contains(i) else { return nil }
    let h = hunks[i], lines = editorHunkLines(tab.text)
    let new = h.newCount == 0 ? [] : Array(lines[(h.newStart - 1)..<(h.newStart - 1 + h.newCount)])
    let after = h.kind == .deleted ? h.newStart - 1 : h.newStart + h.newCount - 1
    let title = "\(i + 1) of \(hunks.count) change\(hunks.count == 1 ? "" : "s")"
    return EditorPeekView(index: i, count: hunks.count, afterLine: after, title: title, old: h.oldLines, new: new)
}

/// Revert's `editor_replace_range`, for the active tab's open peek: its path, the range and the old lines.
public func editorPeekRevert(_ s: EditorSnapshot) -> (path: String, range: EditorRange, text: String)? {
    guard let a = s.active, a < s.tabs.count, let path = s.tabs[a].path, let i = s.tabs[a].peek,
          let base = s.tabs[a].baseline else { return nil }
    let hunks = editorHunks(base: base, text: s.tabs[a].text)
    guard hunks.indices.contains(i) else { return nil }
    let e = editorRevertEdit(hunks[i], text: s.tabs[a].text)
    return (path, e.range, e.text)
}

/// The peek index after `text` changed under it (R12): clamped to the hunks there are, nil when none.
public func editorPeekClamped(_ peek: Int?, baseline: String?, text: String) -> Int? {
    guard let peek, let baseline else { return nil }
    let n = editorHunks(base: baseline, text: text).count
    return n == 0 ? nil : min(peek, n - 1)
}

/// `range` as an action's `range` param.
public func editorRangeParam(_ r: EditorRange) -> JSONValue {
    func p(_ x: EditorPosition) -> JSONValue {
        .object(["line": .integer(Int64(x.line)), "column": .integer(Int64(x.column))])
    }
    return .object(["start": p(r.start), "end": p(r.end)])
}
```

- `PaneStore.editorBufferDidChange`, inside its update, sets `s.tabs[i].peek = nil`, because typing
  closes the peek. Comment it with the spec's line.
- `editor_replace_range`, after `s.tabs[i].text = …`, sets
  `s.tabs[i].peek = editorPeekClamped(s.tabs[i].peek, baseline: s.tabs[i].baseline, text: s.tabs[i].text)`.
- `EditorPaneKind.readPane`: add
  `o["peek"] = tab.flatMap(editorPeekView).map { v in .object(["index": .number(Double(v.index)), "count": .number(Double(v.count)), "line": .number(Double(v.afterLine))]) } ?? .null`.

- [ ] **Step 3: The actions**

`EditorActionError` gains these cases:

```swift
    /// The active tab has no change marks: untracked, outside a repository, scratch, read-only, or a diff.
    case noMarks(action: String)
    /// `editor_peek` on a line with no mark.
    case noChange(line: Int)
    /// `editor_peek_step` with no peek open.
    case noPeek(action: String)
```

Their descriptions:
- `"\(action): the active tab has no change marks (it is untracked, outside a repository, a scratch or read-only tab, or a diff)"`
- `"editor_peek: line \(line) has no change mark"`
- `"\(action): no peek is open; open one with editor_peek on a marked line"`

```swift
    await registry.register(Action(
        name: "editor_peek",
        description: "Open the peek on the change marked at line (1-based) of the editor pane's active file tab: "
            + "the hunk's old lines over its new ones, under it in the file, with previous / next and Revert. The "
            + "cursor moves to the hunk. Marks compare the buffer with the file's index text. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["line": .object(["type": .string("integer")])], required: ["line"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_peek")
            guard let line = jsonObject(params)?["line"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_peek", param: "line")
            }
            let outcome = await panes.updateEditor(paneId: pane) { s -> EditorPeekOutcome in
                guard let i = editorTabIndex(s, path: nil) else { return .noTab }
                guard let base = s.tabs[i].baseline, !s.tabs[i].readOnly else { return .noMarks }
                let hunks = editorHunks(base: base, text: s.tabs[i].text)
                guard let h = editorHunkIndex(at: line, in: hunks) else { return .noChange }
                s.tabs[i].peek = h
                s.tabs[i].cursor = EditorPosition(line: editorGutterMarks(hunks)[h].start, column: 1)
                s.tabs[i].selection = nil
                return .ok
            }
            switch outcome {
            case .noTab: throw EditorActionError.noTab(action: "editor_peek")
            case .noMarks: throw EditorActionError.noMarks(action: "editor_peek")
            case .noChange: throw EditorActionError.noChange(line: line)
            case .noPeek, .ok: break
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_peek_step",
        description: "Move the open peek delta changes (1 next, -1 previous) through the active tab's changes, "
            + "stopping at either end; the cursor moves with it. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["delta": .object(["type": .string("integer")])], required: ["delta"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_peek_step")
            guard let delta = jsonObject(params)?["delta"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_peek_step", param: "delta")
            }
            let outcome = await panes.updateEditor(paneId: pane) { s -> EditorPeekOutcome in
                guard let i = editorTabIndex(s, path: nil) else { return .noTab }
                guard let p = s.tabs[i].peek, let base = s.tabs[i].baseline else { return .noPeek }
                let hunks = editorHunks(base: base, text: s.tabs[i].text)
                guard !hunks.isEmpty else { s.tabs[i].peek = nil; return .noPeek }
                let next = min(max(p + delta, 0), hunks.count - 1)
                s.tabs[i].peek = next
                s.tabs[i].cursor = EditorPosition(line: editorGutterMarks(hunks)[next].start, column: 1)
                s.tabs[i].selection = nil
                return .ok
            }
            switch outcome {
            case .noTab: throw EditorActionError.noTab(action: "editor_peek_step")
            case .noPeek, .noMarks, .noChange: throw EditorActionError.noPeek(action: "editor_peek_step")
            case .ok: break
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_peek_close",
        description: "Close the active tab's peek; the cursor stays where it is. Nothing to close is not an error.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_peek_close")
            await panes.updateEditor(paneId: pane) { s in
                if let i = editorTabIndex(s, path: nil) { s.tabs[i].peek = nil }
            }
            return await reply(pane)
        }))
```

At file scope: `private enum EditorPeekOutcome: Sendable { case ok, noTab, noMarks, noChange, noPeek }`.

Run: `cd app && swift test --filter 'EditorPeekTests|ActionClassificationTests'`. Expected: PASS.

- [ ] **Step 4: The render step**

In `EditorRenderer.swift`:
- The protocol gains

```swift
    /// Show `peek` under its hunk in `key`'s model as a view zone, or remove it (nil). One per pane.
    func showPeek(key: String, _ peek: EditorPeekView?)
```

- `EditorRenderStep` gains `case peek(key: String, EditorPeekView?)`.
- `EditorRendered` gains `public var peek: EditorPeekView?`, last in its init, default nil.
- In `editorRenderSteps`, the file-tab branches add the step last:
  - **Rendered before:** `let was = key == active ? r.peek : nil`, then
    `let now = editorPeekView(t); if now != was { steps.append(.peek(key: key, now)) }`. A tab
    re-shown starts with no zone, since `wakilShowModel` removes it.
  - **New:** `if let now = editorPeekView(t) { steps.append(.peek(key: key, now)) }`.
- `editorRenderedAfter` sets `peek: editorPeekView(t)` on the active file tab's entry.
- `editorApply` adds `case .peek(let key, let p): renderer.showPeek(key: key, p)`.

- [ ] **Step 5: The page and the pane**

`monaco-host.html`, CSS:

```css
.wakil-peek{pointer-events:auto;background:#11141e;border-top:1px solid #2a2f40;border-bottom:1px solid #2a2f40;font:12px Menlo,monospace}
.wakil-peek-head{display:flex;gap:10px;padding:2px 8px;color:rgba(232,236,246,.62);font-size:11px}
.wakil-peek-head button{all:unset;cursor:pointer;color:rgba(232,236,246,.9)}
.wakil-peek-old{color:rgba(232,236,246,.45);padding-left:8px;white-space:pre}
.wakil-peek-new{color:#8be0c8;padding-left:8px;white-space:pre}
```

JS, inside the editor code:

```js
      // 3b-iii: the peek — one view zone under a hunk, its old lines muted over its new ones in green.
      // Its buttons post back; the app dispatches (editor_peek_step / _close, and Revert's edit).
      let peekZone = null;
      function dropPeek(acc) { if (peekZone !== null) { acc.removeZone(peekZone); peekZone = null; } }
      window.wakilPeek = function (key, p) {
        ed.changeViewZones(function (acc) {
          dropPeek(acc);
          if (!p || key !== current) return;
          const node = document.createElement('div'); node.className = 'wakil-peek';
          const head = document.createElement('div'); head.className = 'wakil-peek-head';
          const title = document.createElement('span'); title.textContent = p.title; head.appendChild(title);
          [['↑', 'up'], ['↓', 'down'], ['Revert', 'revert'], ['×', 'close']].forEach(function (b) {
            const el = document.createElement('button'); el.textContent = b[0];
            el.addEventListener('mousedown', function (e) {
              e.preventDefault(); e.stopPropagation();
              post({ type: 'peek', key: key, op: b[1] });
            });
            head.appendChild(el);
          });
          node.appendChild(head);
          p.old.forEach(function (l) { const d = document.createElement('div'); d.className = 'wakil-peek-old'; d.textContent = l; node.appendChild(d); });
          p.new.forEach(function (l) { const d = document.createElement('div'); d.className = 'wakil-peek-new'; d.textContent = l; node.appendChild(d); });
          peekZone = acc.addZone({ afterLineNumber: p.afterLine, heightInLines: 1 + p.old.length + p.new.length, domNode: node });
        });
        if (p && key === current) ed.revealLinesInCenterIfOutsideViewport(Math.max(p.afterLine, 1), p.afterLine + 1 + p.old.length + p.new.length);
      };
```

`wakilShowModel` and `wakilShowDiff` each call `ed.changeViewZones(dropPeek);` first.

`MonacoEditorRenderer.swift`:

```swift
    /// A peek control pressed in `key`: "up", "down", "revert" or "close".
    var onPeek: ((String, String) -> Void)?

    func showPeek(key: String, _ p: EditorPeekView?) {
        guard let p else { run("wakilPeek(\(Self.jsString(key)),null)"); return }
        let old = p.old.map(Self.jsString).joined(separator: ","), new = p.new.map(Self.jsString).joined(separator: ",")
        run("wakilPeek(\(Self.jsString(key)),{title:\(Self.jsString(p.title)),afterLine:\(p.afterLine),old:[\(old)],new:[\(new)]})")
    }
```

In `receive`, add
`case "peek": if let key = body["key"] as? String, let op = body["op"] as? String { onPeek?(key, op) }`.

In `EditorHost`:
- Add `@ObservationIgnored var peekPressed: ((String) -> Void)?`.
- In `start()`: `made.onPeek = { [weak self] _, op in self?.peekPressed?(op) }`.

In `EditorPane`, where the host's closures are handed in:

```swift
        host.markClicked = { _, line in Task { await dispatch("editor_peek", ["line": .integer(Int64(line))]) } }
        host.peekPressed = { op in peekOp(op) }
        host.onKey = { key in
            if comparing != nil { if key == "escape" { closeCompare() }; return }
            peekOp(key == "escape" ? "close" : key)
        }
```

```swift
    /// A peek control or key (R13): step, close, or Revert — `editor_replace_range` with the hunk's
    /// old lines, which asks nothing (Rule 1) and is undone with ⌘Z.
    private func peekOp(_ op: String) {
        Task {
            switch op {
            case "up": await dispatch("editor_peek_step", ["delta": .integer(-1)])
            case "down": await dispatch("editor_peek_step", ["delta": .integer(1)])
            case "close": await dispatch("editor_peek_close", [:])
            case "revert":
                guard let r = editorPeekRevert(snapshot) else { return }
                await dispatch("editor_replace_range", ["path": .string(r.path), "range": editorRangeParam(r.range),
                                                        "text": .string(r.text)])
            default: break
            }
        }
    }
```

Esc keeps the keyboard in Monaco, so focus stays where it was (Rule 6).

The captured keys now follow the peek too. The `onChange` from Task 4 becomes:

```swift
        .onChange(of: editorCapturedKeys(comparing: comparing != nil, peek: activeTab?.peek != nil), initial: true) { _, keys in
            host.renderer?.captureKeys(keys)
        }
```

- [ ] **Step 6: Run and look**

Run: `make build && make test && make app-test`. Expected: green.

Open `e2e-api/app.txt`, then click the amber bar. Expect:
- the peek opens under line 2 reading `1 of 2 changes · ↑ ↓ · Revert · ×`, with `line two` muted over
  `line two, staged` in green;
- ↓ moves to the green hunk, and Revert drops line 3: the tab is dirty and the file untouched;
- ⌘Z brings it back. Esc closes the peek, and the cursor stays.

Clicks on the peek's buttons are a ruling to measure in the walk. If Monaco swallows the `mousedown`,
the fallback is `ed.onMouseDown` with `e.target.type === CONTENT_VIEW_ZONE` and `e.target.element`'s
button text.

- [ ] **Step 7: Commit and open PR 5**

```bash
git switch -c yehia-khalil/3b-iii-5-peek
git add app/Sources app/Tests
git commit -m "3b-iii PR 5: the peek — open from a mark, step, Esc, and Revert as an undoable buffer edit"
gh stack submit
```

---
### Task 8: Charter, spec amendments, the Cover hand-off and the acceptance runbook (PR 6)

**Files:**
- Modify: `docs/wakil/decisions.md` (Decision 40, after 39).
- Modify: `docs/wakil/design-language.md`: §11's Git and Editor rows, and §15's open items.
- Modify: `docs/superpowers/specs/2026-10-15-3b-iii-changes-view-design.md`. Add a dated amendment
  section, and edit the body where a ruling changed it.
- Create: `docs/wakil/phase-3b-iii-acceptance.md`.
- Unchanged: the 3b-ii spec's roadmap table keeps 3b-iii's row (spec, *Charter changes*).

- [ ] **Step 1: Decision 40**

After 39, in its numbered style:

```markdown
40. **The Git pane is the editor's Changes view; gutter marks and the peek ship with it.**
    *(2026-10-15, operator, during the 3b-iii design —
    `docs/superpowers/specs/2026-10-15-3b-iii-changes-view-design.md`.)*
    Decision 36's fold, made. The editor's left column has a third view, **Changes** (⌘⇧G): one
    header per root, Staged / Changes / Untracked, and a row opens a read-only **diff tab**
    (`User.php (Changes)`) in the editor's own web view, under the preview-tab rule; ⌘⏎ opens the
    file itself. **The window keeps one git status** (`GitStatus`), read once per root per watcher
    wake while any editor pane is open, and everything that shows git reads it. A file tab in a
    repository shows **gutter marks** against the index, computed in WakilKit from the buffer; a mark
    opens an inline **peek** whose **Revert** is a buffer edit — undoable, unsaved until ⌘S — and so
    asks nothing (Rule 1). The Files tree shows each changed file's status letter. **The Git pane
    kind is gone**, and a layout that saved one opens it as an editor pane on Changes — the first kind
    migration; every other unknown kind is still dropped. Nothing writes to git: stage, unstage,
    commit and discard stay 3a-ii's.
    *Reverse if:* the Changes view is found unable to show something the operator relied on the Git
    pane's spine or names column for — then that piece comes back inside the editor, not as a pane.
```

- [ ] **Step 2: Design language**

§11:
- The **Git** row's notes become: *"Folded into the editor (3b-iii, Decision 40): the editor's
  left column's **Changes** view (⌘⇧G) — one header per root, Staged / Changes / Untracked, status
  letters in §5's tones — opens read-only inline diff tabs in the editor. No pane of its own."*
- The **Editor** row gains: *"A file in a repository shows gutter marks against the index — a green
  bar for added lines, amber for changed, a muted triangle where lines were deleted — and a click on
  one opens the peek: the change's old lines over its new, with ↑ ↓, Revert (an undoable buffer edit)
  and ×. The Files tree shows a changed file's status letter."*

§15: strike *"Editor gutter change-indicators + inline diff (vs Git pane only)"*, adding *"— settled by
3b-iii (Decision 40)"*. *"Commit-history / branch graph in the Git pane"* and *"Side-by-side diff in
the Git pane"* become *"… in the editor's Changes"*, still deferred.

§1's *"Two sidebars are sanctioned, both inside a pane: the Git pane's column of file names …"*: the
Git pane's names column is gone. Rewrite the sentence so its first sanctioned sidebar is the editor's
left column, then read §1 whole and keep its count true.

- [ ] **Step 3: The spec's amendments**

Append to the spec:

```markdown
## Amendment — 2026-10-16, while planning (`docs/superpowers/plans/2026-10-16-3b-iii-changes-view.md`)

The rulings R1–R14 of the plan, each one line here with its reason:
```

Then one bullet for each of R1–R14, copied from this plan's *Rulings* section. Edit the body to match:
- *Errors and edges*, the older-build bullet: say what the check found (R1).
- *WakilApp*: Compare shares the page (R2), and `--probe-monaco` is deleted (R3).
- *WakilKit*:
  - the status is an actor, not pane state (R4);
  - `editor_refresh` takes `what` (R5);
  - the reselect needs no `before` (R6);
  - diff tabs are not saved (R7);
  - a migrated pane keeps its id (R8);
  - a missing final newline is not a hunk (R9).
- The action table: ⌘⏎ is Maximize Pane outside a diff (R10).
- *The peek*: Revert lands on the next hunk or the one before (R12).

- [ ] **Step 4: Hand Cover its list (R14)**

This is the next rung's input, not a check this plan writes. Put it in the PR 6 body, and in the
acceptance doc's *Cover* section, word for word:

```markdown
**For the e2e auditor (`docs/agents/e2e.md`)** — what 3b-iii touched, for checks to cover:
- Rewrite 3a-i's six deleted checks as `3b-iii-changes-{list,drill,keys,live,press,voice-hint}` against
  the editor: the Changes rows and headers (`editor.changes.root:<…>`, `editor.changes.row:<…>/<…>:<…>`,
  `editor.changes.rootError:<…>`), collapse, ↑↓ and Return, live updates from a terminal, the voice
  hint for `BookingController.php`.
- New: ⌘⇧G's toggle; a diff tab's preview rule, its title, *No longer changed*, the banner
  (`editor.diff.loading`, `.error`, `.banner`, `.gone`); ⌘⏎ opening the file (and maximizing on a
  scratch tab); the tree's status letters; the peek (open from a mark, ↑↓, Revert dirty and ⌘Z, Esc);
  a saved Git pane migrating (seed a layout file with a `git` pane).
- `uncoverable.tsv` rows for any action no control dispatches by click: likely `editor_peek_step`
  (keys), `editor_changes_step` (keys), `editor_open_file` (a key), each on `git_step`'s precedent.
```

- [ ] **Step 5: The acceptance runbook**

`docs/wakil/phase-3b-iii-acceptance.md`, in 3b-ii-b's shape:
- the header links the spec and the plan;
- **Not yet walked.**;
- the exit criterion from the spec;
- Decision 40 and the §11 rows;
- a `## 0. Setup` that builds a two-root git project in `/tmp/walk-changes`, as 3b-ii-b's does. Give
  `api` a staged-and-changed file, an untracked one, a deleted one and a rename; give `portal` one
  change; and include a non-repo root;
- the machine-walk markers, empty:

```markdown
<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
```

- the human half, **ten checks**, chosen for what a test cannot see (`docs/agents/workflow.md`):

| # | Check | Expect |
|---|---|---|
| 1 | Launch onto a layout saved with a Git pane | The pane is the editor, in the same place, its column on Changes |
| 2 | ⌘⇧G three times from an editor on Files | Changes, then hidden, then Changes again; the keyboard is in the list each time it shows |
| 3 | Look at the Changes view | Headers `api · main · …`, `docs · not a git repository`; letters green / amber / muted, **no red**; a rename reads `old → new` |
| 4 | In a terminal pane, `git add` the changed file, then commit it | The row moves to Staged within about half a second, then leaves; the highlight moves to its neighbour, not the top |
| 5 | Click a row, then another; double-click a third | One preview tab replaced, then a pinned tab beside it; additions green, deletions muted, inline |
| 6 | In a diff tab, put the cursor on a line and press ⌘⏎ | The file opens as a tab at that line, the diff tab still open; on a scratch tab ⌘⏎ maximizes as before |
| 7 | Type in a tracked file | An amber bar beside the changed line within a moment; a deleted line leaves a muted triangle between two lines |
| 8 | Click a mark; press ↓, then Revert, then ⌘Z | The peek reads `1 of N changes · ↑ ↓ · Revert · ×`; Revert undoes that change in the buffer (tab dirty, file untouched); ⌘Z brings it back |
| 9 | Esc in the peek; then type | The peek closes and the cursor stays; typing with the peek open closes it, the marks stay |
| 10 | The Files tree | `M` beside the changed file, `?` beside the untracked one, folders untinted, ignored files still dimmed |

- [ ] **Step 6: Commit and open PR 6**

```bash
git switch -c yehia-khalil/3b-iii-6-walk
git add docs
git commit -m "3b-iii PR 6: Decision 40, design language, the spec's planning amendments, the acceptance runbook"
gh stack submit
```

After PR 6 comes **Cover**: the e2e auditor with Step 4's list. Then **Walk**: `make e2e-runbook
E2E_RUNBOOK=docs/wakil/phase-3b-iii-acceptance.md`, and the operator walks the ten. `Met` in
`north-star.md` §8 and the `phase-log.md` entry are written after the walk, not before.

---

## Self-review

**Spec coverage.**

| Spec | Task |
|---|---|
| The Changes view, ⌘⇧G | 2 |
| One header per root, collapse per pane | 2 |
| The three groups and their rows | 2 |
| ↑↓, Return | 2 (Task 3 makes them open) |
| Live updates | 1, 2 (`what: git` per wake) |
| Not-a-repo root | 2 (`gitRootLine`) |
| Diff tab title and two tabs | 3 |
| Read-only, inline, themed | 4 (the theme's diff colours carry over) |
| Which revisions each group diffs, untracked and deleted | 3 |
| The preview rule | 3 |
| ⌘⏎ and when it is not offered | 3, R10 |
| The banner (Rule 8) | 4 (`diffLine`) |
| Live diff and *No longer changed* | 3 |
| Gutter marks, against the index, from the buffer, refetched | 6 |
| No marks on untracked, outside a repository, scratch or read-only | 6 |
| The peek, step, Revert, Esc, typing | 7 |
| Tree letters | 2 |
| Every agent action | 2, 3, 7 |
| `git_fold`/`git_unfold` deleted | 5 |
| Window status, one read per wake, the watcher's terms, a start reads first | 1 |
| `EditorColumnState` fields saved with the layout | 2 |
| `.diff` subject, `GitDiffState` | 3 |
| `editorHunks` | 6 |
| Peek as tab state | 7 |
| Layout migration | 5 |
| The deletions | 5 |
| One web view per pane, `showDiff`, `DiffRenderer` folded | 4 |
| Rules 1, 4/5, 6, 7, 8 | 7, 3, 2/7, 3, 2/4 |
| The older-build decode | 1, R1 |
| Unit tests listed by the spec | 1, 2, 3, 5, 6, 7 |
| The e2e list | 8 → Cover |
| The walk | 8 |
| The charter changes | 8 |

No gaps.

**Placeholders.** The deletions in Task 5 are by file and by grep, with each test file's change named.
The compiler and `make app-test` list anything a hand-made list would miss. Task 8's amendment
bullets point at R1–R14 in this file rather than repeating them; Task 8 copies them.

**Type consistency.**
- `EditorChangesRow.group` is a `String` everywhere (`Layout/` cannot see `GitGroup`). It is converted
  with `GitGroup(rawValue:)` only after `changesRow` has validated it.
- `.diff(root:path:group:)`'s `path` is relative to `root` in Tasks 3–5, and `editor_open_file` joins
  them.
- `GitDiffState` is the same type in Tasks 3 and 4.
- `EditorGutterMark.kind`'s raw values are the page's CSS suffixes.
- `editorCapturedKeys` is defined in Task 4 and extended by its call site in Task 7.

**Review Focus.** Each of its five lines names its test, in Tasks 1, 2, 3 and 6.
