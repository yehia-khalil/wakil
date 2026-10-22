# 3a-ii-b Ranges and Drafts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage and unstage selected line ranges from a diff tab, and draft a commit message with the org's quick model from the commit box's ✨, by hand, by voice and by the agent.

**Architecture:** Range staging is pure Swift over the diff tab's two texts (`EditorHunks.swift`), written through 3a-ii's unchanged `git_stage_hunk` with its blob guard. Two new `.mutate` actions sit beside the 3a-ii writes. The draft is a Decision 42 quick task (`CommitDraft`: a prompt and a parser over `QuickTasks.respond`), fed by `git_diff` widened to a whole root, behind a new per-org `commitDrafts` switch, and surfaced as a `.control` action and a ✨ in the commit box.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-git`, `cmd/wakil-ctx`), Swift 6 / SwiftUI (`app/Sources/WakilKit`, `app/Sources/WakilApp`), Swift Testing, Monaco in `monaco-host.html`.

**Spec:** `docs/superpowers/specs/2026-10-22-3a-ii-b-ranges-and-drafts-design.md` (with its 2026-10-22 amendment: Unstage Selected Ranges).

## Global Constraints

- Action names exactly: `editor_changes_stage_ranges`, `editor_changes_unstage_ranges`, `editor_changes_draft_message`.
- Range actions: kind `.mutate`, `audience: .agentReachable`, price the same `price` value `editor_changes_stage_hunk` uses (allow everywhere). Draft: kind `.control`, `.agentReachable`.
- No new Go write tool: range writes go through `git_stage_hunk` (`root`, `path`, `content`, `expect`) unchanged.
- Refusal texts verbatim: `the selection holds no change`; `the change moved — reopen the diff` (Go's stale-guard words are rewritten to this for the two range actions); `commit drafts are off for <org> — Settings → Providers → Quick tasks`; `nothing to draft from: <root name> has no changes`; `the model returned no message`.
- Draft input cap: 1,500 diff lines; past it, every file as one `path +a −d` line and the prompt says the diff was cut. Style examples: up to 5 of the root's `changesHistory`. `maxTokens: 300`. JSON schema `{"message": string}`. Fallback on.
- Switch: `commitDrafts`, per org, default **on**; Settings row label `Commit drafts`, hint `Drafts a message from what you are about to commit, when you press ✨`, identifier `settings.org.commitDrafts`.
- Accessibility identifiers: `editor.diff.stageRanges`, `editor.diff.unstageRanges`, `editor.changes.<root name>.draft`.
- Button titles: `Stage Selected Ranges`, `Unstage Selected Ranges`; ✨ help `Draft Message`.
- Never add Co-Authored-By or "Generated with" lines to commits. Committed docs hold no home paths.
- 2e-ii is being built in parallel and touches Settings → Organisation and probably `orgupdate.go` / `org.go`. Keep the Go switch change minimal and expect a rebase.

## Rulings (where this plan settles what the spec left to mechanism)

- **R1 — Multi-cursor ranges are read at press time, not reported.** `EditorTab.selection` stays one range: the primary one, which the diff report now sends instead of `null`. It drives the button's enabled state. A press (header button, context menu, ⌘K) asks the page for **all** selections with `wakilDiffSelections()` and passes them as `ranges`. This saves widening the `view` message and `viewReported`'s signature. Cost if wrong: the button stays disabled when only a non-primary cursor touches a change.
- **R2 — The draft action reaches the window through a sink.** Actions are registered in `AppWiring` before any `WindowModel` exists. `registerEditorActions` gains `draft: CommitDraftSink`, an actor holding an optional `@Sendable (String) async throws -> String` (root → message) that `WindowModel` sets when its session starts and clears on shutdown. With nothing bound, the action refuses with the `noProvider` words. Cost if wrong: one wiring move.
- **R3 — ⌘Z after a draft is the App's undo, not the model's.** `WindowModel.changesDraft(root:)` returns the text it replaced. `EditorColumn` registers one undo on the window's `UndoManager` that puts that text back through `changes.edit`. Cost if wrong: walk-only; the restore path is unit-tested on the model.
- **R4 — "Typing cancels a draft in flight"** is `changesMessageEdited` cancelling `changesDraftTasks[root]`. A reply that lands after a cancel is dropped.

## Review Focus

1. **A selection that ends at column 1 of the next line** (a whole-line drag) must not include that next line. If it did, an adjacent hunk would be staged by accident. Test in Task 1 (pure) and pinned in Task 5's JS (`end.column == 1 && end.line > start.line → end.line - 1`).
2. **A file whose last line has no newline**, with the selection on that last line. The staged text must not gain or lose a final newline. Test in Task 1.
3. **Stage ranges on a diff tab whose index moved underneath it**, after the operator staged in a terminal. Refused with `the change moved — reopen the diff`, never a silent overwrite. Test in Task 2.
4. **A draft arrives after an org switch, or after the operator typed.** The box is untouched. Test in Task 4.
5. **A staged diff of only binary files, or of a rename.** The draft input still names each file and is never empty. Test in Task 3.

---

### Task 1: Pure range staging and unstaging

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorHunks.swift` (beside `editorStagedText(base:text:hunk:)`, ~line 224)
- Test: `app/Tests/WakilKitTests/EditorRangesTests.swift` (new)

**Interfaces:**
- Consumes: `editorHunks(base:text:)`, `editorGutterMarks(_:)`, `editorRevertEdit(_:text:)`, `editorReplacing(_:_:with:)` (all in `EditorHunks.swift`).
- Produces:
  - `public struct EditorLineSpan: Sendable, Equatable, Codable { public var start: Int; public var end: Int }` (1-based, inclusive)
  - `public func editorLineSpans(_ ranges: [EditorRange]) -> [EditorLineSpan]`: applies the column-1 rule (Review Focus 1); a caret becomes one line.
  - `public func editorRangesTouchChange(base: String, text: String, ranges: [EditorLineSpan]) -> Bool`
  - `public func editorStagedText(base: String, text: String, ranges: [EditorLineSpan]) -> String?`: `base` is the index text, `text` the working tree. Returns the new index text.
  - `public func editorUnstagedText(base: String, text: String, ranges: [EditorLineSpan]) -> String?`: `base` is HEAD (`""` for a file new in the index), `text` the index text. Returns the new index text.

The touch rule, shared by all three: a hunk is touched when a span intersects `newStart…newStart+newCount-1` (added and changed), or covers its gutter mark's line (deleted: `editorGutterMarks`). Staging, per touched hunk: added → only the selected new lines go in; changed → the selected new lines go in and **all** old lines come out; deleted → the deletion goes in. Unstaging is the mirror on `(HEAD, index)`: the touched part is reverted toward `base`. Both return nil when nothing is touched.

- [ ] **Step 1: Write the failing tests** in `EditorRangesTests.swift`, `@Suite struct EditorRangesTests`:
  - `stagesOnlyTheSelectedLinesOfAnAddedHunk`: base `"a\nd\n"`, text `"a\nb\nc\nx\nd\n"`, spans `[2…3]` → `"a\nb\nc\nd\n"`.
  - `aChangedHunkWithOneNewLineSelectedDropsAllItsOldLines`: base `"a\nold1\nold2\nz\n"`, text `"a\nnew1\nnew2\nz\n"`, spans `[2…2]` → `"a\nnew1\nz\n"`.
  - `aDeletionIsStagedFromTheLineItsMarkSitsOn`: base `"a\nb\nc\n"`, text `"a\nc\n"`, spans `[1…1]` → `"a\nc\n"`; spans `[2…2]` → nil.
  - `aCaretStagesTheHunkUnderIt`: `editorLineSpans([EditorRange(start: (3,4), end: (3,4))]) == [EditorLineSpan(start: 3, end: 3)]`.
  - `aWholeLineDragDoesNotTakeTheNextLine`: `editorLineSpans([EditorRange(start: (2,1), end: (4,1))]) == [EditorLineSpan(start: 2, end: 3)]`.
  - `twoRangesStageTheirUnion` and `contextOnlyIsNil` (spans on unchanged lines → nil, and `editorRangesTouchChange` false).
  - `theLastLineWithoutANewlineKeepsItsEnding`: base `"a\nb"`, text `"a\nb\nc"`, spans `[3…3]` → `"a\nb\nc"`.
  - `crlfLinesKeepTheirEndings`: base `"a\r\nb\r\n"`, text `"a\r\nX\r\nb\r\n"`, spans `[2…2]` → `"a\r\nX\r\nb\r\n"`.
  - `stageRoundTripLeavesOnlyTheUnselectedChanges`: for a three-hunk pair, stage hunk 2's lines; `editorHunks(base: staged, text: text).count == 2`.
  - `unstageRevertsOnlyTheSelectedPart`: HEAD `"a\nb\n"`, index `"a\nX\nY\nb\n"`, spans `[2…2]` → `"a\nY\nb\n"`; a new file (HEAD `""`, index `"p\nq\n"`) with spans `[1…2]` → `""`.
- [ ] **Step 2: Run** `cd app && swift test --filter EditorRangesTests`. Expected: FAIL (`cannot find 'editorStagedText'` overload / `EditorLineSpan`).
- [ ] **Step 3: Implement** the five symbols above in `EditorHunks.swift`. Build the result line by line from the hunks; do not route it through `editorRevertEdit`, which works on whole hunks. Keep the original line terminators by splitting raw text on `"\n"` scalars, as `editorRawLines` does.
- [ ] **Step 4: Run** `cd app && swift test --filter "EditorRangesTests|EditorHunksTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "3a-ii-b: stage and unstage selected line ranges, pure"`.

### Task 2: `editor_changes_stage_ranges` and `editor_changes_unstage_ranges`

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorChangesWrites.swift` (after `editor_changes_stage_hunk`)
- Modify: `app/Sources/WakilKit/App/WindowModel+ChangesWrites.swift` (beside `changesStageHunk()`)
- Modify: `app/Tests/WakilKitTests/WindowModelPaletteTests.swift:938` (two names into the list), `app/Tests/WakilKitTests/AppWiringTests.swift:252` if it lists the editor_changes set
- Test: `app/Tests/WakilKitTests/EditorChangesWritesTests.swift` (the `WriteGit` stub gains `git_show` answers keyed by `rev`)

**Interfaces:**
- Consumes: Task 1's `EditorLineSpan`, `editorStagedText(base:text:ranges:)`, `editorUnstagedText(base:text:ranges:)`; `gitBlobId(_:)`; the file's `write(root, action:)`, `call(git, …)`, `relative(_:to:)`; `EditorTab.diffState` and `.subject` (`.diff(root, path, group)`); `gitDiffBanner`.
- Produces:
  - Params for both: `path` (absolute, required), `ranges` (`[{start, end}]`, optional), `pane` (optional).
  - `WindowModel.changesStageRanges(_ ranges: [EditorLineSpan]) async` and `changesUnstageRanges(_ ranges: [EditorLineSpan]) async`: they act on the focused pane's active diff tab, as `changesStageHunk()` does.

Texts: stage takes a Changes diff tab for `path` (the given pane first), with `(original, modified)` = (index, worktree). Unstage takes a Staged diff tab, with (HEAD, index). With no such tab open, both are read with `git_show` (`rev` `index`/`worktree`, or `HEAD`/`index`; an absent HEAD side is `""`). `ranges` defaults to the tab's `selection` through `editorLineSpans`; with no tab and no `ranges`, it is `missingParam`. `expect` = `gitBlobId(original)` for stage and `gitBlobId(modified)` (the index) for unstage. Refuse before any write when: the diff is binary or truncated (name `gitDiffBanner`'s words), the file is conflicted (`U`), a side is over `editorHunksLineCap`, a Staged file is `D`, or the result is nil (`the selection holds no change`). Rewrite Go's stale-guard error to `the change moved — reopen the diff`.

- [ ] **Step 1: Write the failing tests**:
  - `stageRangesSendsTheIndexTextWithOnlyTheSelectedLinesAndTheIndexBlob`: diff tab index `"a\n"` / worktree `"a\nb\nc\n"`, ranges `[{2,2}]` → `git_stage_hunk` `content == "a\nb\n"`, `expect == gitBlobId("a\n")`.
  - `unstageRangesExpectsTheIndexBlob`: Staged tab HEAD `"a\n"` / index `"a\nb\n"`, ranges `[{2,2}]` → `content == "a\n"`, `expect == gitBlobId("a\nb\n")`.
  - `stageRangesWithNoTabReadsBothSidesFromGit`: two `git_show` calls (`index`, `worktree`) before `git_stage_hunk`.
  - `stageRangesDefaultsToTheTabsSelection`.
  - Refusals, each asserting `git_stage_hunk` count 0 and the message: `refusesASelectionWithNoChange`, `refusesABinaryDiff`, `refusesATruncatedDiff`, `refusesAConflictedFile`, `refusesAStagedDeletionForUnstage`.
  - `aMovedIndexIsReportedAsReopenTheDiff`: the stub's `git_stage_hunk` fails with the guard error → the thrown text contains `the change moved — reopen the diff`.
  - `rangeActionsAreAllowedMutationsForTheAgentInProduction` (kind, audience, price, through `f.dispatch`).
- [ ] **Step 2: Run** `cd app && swift test --filter EditorChangesWritesTests`. Expected: FAIL (`unknown action editor_changes_stage_ranges`).
- [ ] **Step 3: Implement** both actions, sharing one private helper for finding the tab or reading the texts and for the refusals. Implement the two `WindowModel` methods. Add the names to the palette and wiring test lists.
- [ ] **Step 4: Run** `cd app && swift test --filter "EditorChangesWritesTests|WindowModelPaletteTests|AppWiringTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "3a-ii-b: stage and unstage selected ranges as actions"`.

### Task 3: Go: `git_diff` over a whole root, and the `commitDrafts` switch

**Files:**
- Modify: `internal/wakilcore/gitdiff.go:34` (`GitDiff`), `cmd/wakil-git/main.go:22-25` (`diffArg.Path` optional, schema text), `:121` (description)
- Modify: `internal/wakilcore/org.go:49-53` (`CommitDrafts *bool \`json:"commitDrafts,omitempty"\``), `orgupdate.go:24-62` (`OrgPatch.CommitDrafts`), `configtree.go:22-24, 207-208` (`CommitDrafts bool \`json:"commitDrafts"\``, `resolveOrgSwitch(record.CommitDrafts, true)`), `cmd/wakil-ctx/main.go:161, 505`
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift:180-189` (`commitDrafts: Bool = true`), `WindowModel+QuickTasks.swift:134` (`OrganisationSwitch` gains `commitDrafts`), `rebuildQuickTasks` sets `commitDraftsEnabled = tree.org.commitDrafts` (new `WindowModel` property, reset to false at the top like `fastPathEnabled`)
- Test: `internal/wakilcore/gitdiff_test.go`, `internal/wakilcore/orgupdate_test.go`, `app/Tests/WakilKitTests/WindowModelQuickTasksTests.swift`

**Interfaces:**
- Produces: `GitDiff(ctx, g, "", side)` = the root's whole diff (no pathspec after `--`). `git_diff` accepts `path` omitted or `""`. `SettingsTree.Org.commitDrafts`, `WindowModel.commitDraftsEnabled: Bool`, `WindowModel.OrganisationSwitch.commitDrafts`.

- [ ] **Step 1: Write the failing tests**:
  - Go `TestGitDiffWithNoPathCoversTheWholeRoot`: a temp repo with two staged files (one binary) and one renamed. `GitDiff(…, "", "staged")` text contains both paths and `Binary files`, and `Binary` is false.
  - Go: extend `TestUpdateOrgSetsTheQuickTaskSwitches` with `CommitDrafts: &off`, and `TestConfigTreeResolvesTheQuickTaskSwitches` with a default `tree.Org.CommitDrafts == true`.
  - Swift `commitDraftsFollowsTheOrgSwitch` in `WindowModelQuickTasksTests`: a tree with `commitDrafts: false` → `commitDraftsEnabled == false` after `rebuildQuickTasks()`.
- [ ] **Step 2: Run** `go test ./internal/wakilcore -run 'GitDiff|QuickTaskSwitches'` and `cd app && swift test --filter WindowModelQuickTasksTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the Go and Swift changes listed under Files. In `GitDiff`, an empty `path` skips `ResolvePath` and the binary short-circuit (which is per file), so a root's diff keeps git's `Binary files … differ` lines as text.
- [ ] **Step 4: Run** `make test` and `cd app && swift test --filter WindowModelQuickTasksTests`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "3a-ii-b: git_diff over a whole root; the commitDrafts switch"`.

### Task 4: `CommitDraft`, the window's draft, and the action

**Files:**
- Create: `app/Sources/WakilKit/App/CommitDraft.swift` (pure prompt and parser)
- Create: `app/Sources/WakilKit/App/WindowModel+CommitDraft.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorChangesWrites.swift` or `EditorActions.swift:272` (register `editor_changes_draft_message`; `registerEditorActions` gains `draft: CommitDraftSink`), `app/Sources/WakilKit/App/AppWiring.swift:415` (pass the sink), `WindowModel+ChangesWrites.swift:11` (`changesMessageEdited` cancels a draft in flight)
- Test: `app/Tests/WakilKitTests/CommitDraftTests.swift`, `app/Tests/WakilKitTests/WindowModelCommitDraftTests.swift`

**Interfaces:**
- Consumes: Task 3's `git_diff` with an empty path and `commitDraftsEnabled`; `QuickTasks.respond(_:fallback:)`; `quickTasksGeneration`, `organization`; `changesMessages`, `changesHistory`, `changesHistoryCursor`, `gitRoots` (`GitRootState.files` for untracked rows).
- Produces:
  - `enum CommitDraft { static func request(diff: String, truncated: Bool, stats: [String], untracked: [(path: String, lines: Int)], examples: [String]) -> RespondRequest; static func parse(_ reply: String) throws -> String; static let lineCap = 1_500 }`
  - `actor CommitDraftSink { func bind(_ f: (@Sendable (String) async throws -> String)?); func draft(root: String) async throws -> String }`
  - `WindowModel.changesDraft(root: String) async -> String?`: returns the text it replaced (nil when nothing landed).
  - `WindowModel.changesDrafting: Set<String>` (spinner) and `changesCancelDraft(root:)`.

Flow of `changesDraft`: refuse when the switch is off (error on `changesErrors[root]`, verbatim text). Read the staged diff of the root, or, when the root has nothing staged, the changed diff plus untracked rows. A root with no changes is refused (`nothing to draft from…`). Capture the generation, org and the box text **before** the await. Call `respond` and parse. Land the draft only if the generation and org are unchanged and the task was not cancelled by typing. Clear `changesHistoryCursor[root]`. Errors are shown whole on `changesErrors[root]`, and the box is unchanged. The action handler calls the sink, which calls `changesDraft` on the main actor and returns `{message}`.

- [ ] **Step 1: Write the failing tests**:
  - `CommitDraftTests.theDiffIsCutAtFifteenHundredLinesAndEveryFileStillNamed`: a 2,000-line diff and 3 stat lines → `request.input` holds 1,500 diff lines, all 3 `path +a −d` lines, and the word `cut`.
  - `examplesAreTheLastFiveFromHistory`; `noExamplesAsksForAnImperativeSubject` (instructions contain `imperative`).
  - `parseTakesTheMessageTrimmed` (`{"message":"  Fix login\n"}` → `"Fix login"`); `parseRefusesAnEmptyMessage` (`the model returned no message`).
  - `onlyBinaryFilesStillProduceANonEmptyInput`.
  - `WindowModelCommitDraftTests` (stub quick model and `ToolCaller`): `aDraftFillsAnEmptyBox`; `aDraftReplacesTextAndReturnsWhatItReplaced`; `typingWhileDraftingKeepsTheTypedText`; `aDraftAfterAnOrgSwitchIsDropped`; `theSwitchOffRefusesWithItsWords`; `commitAllDraftsFromChangesAndUntracked` (asserts `git_diff side: changed` and an untracked path in the input); `aModelErrorIsShownWholeAndTheBoxKept`; `theActionReturnsTheMessageAndIsControlAndAgentReachable`.
- [ ] **Step 2: Run** `cd app && swift test --filter "CommitDraft"`. Expected: FAIL.
- [ ] **Step 3: Implement** `CommitDraft.swift`, the sink, `WindowModel+CommitDraft.swift`, the registration and the wiring. Bind the sink where `WindowModel`'s session starts (beside `rebuildQuickTasks`' first call) and unbind it in `shutDownQuickTasks`.
- [ ] **Step 4: Run** `make app-test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "3a-ii-b: draft a commit message with the quick model"`.

### Task 5: WakilApp: diff-tab buttons, context menu, ✨, Settings row

**Files:**
- Modify: `app/Sources/WakilApp/monaco-host.html:131-140` (`reportDiff` posts the primary `selection`; `dme.onDidChangeCursorSelection(reportDiff)`; `window.wakilDiffSelections = () => dme.getSelections().map(…)` returning `[{startLine, startColumn, endLine, endColumn}]`; `dme.addAction` for `Stage Selected Ranges` / `Unstage Selected Ranges`, toggled by a `window.wakilDiffGroup` the app sets with `wakilShowDiff`, posting `{type: 'stageRanges', key}` or `{type: 'unstageRanges', key}`)
- Modify: `app/Sources/WakilApp/MonacoEditorRenderer.swift:200-222` (handle the two messages; `func diffSelections() async -> [EditorRange]` over `evaluateJavaScript`)
- Modify: `app/Sources/WakilApp/EditorPane.swift:491-500` (the header strip: the button beside the banner, enabled by `editorRangesTouchChange` on the tab's `diffState` and `selection`), `Canvas.swift:518` (pass `stageRanges` / `unstageRanges` closures to `model.changesStageRanges` / `changesUnstageRanges`)
- Modify: `app/Sources/WakilApp/EditorColumn.swift:709-800` (`commitBox`: ✨ / spinner / ✕ in the box's top-right; `EditorChangesControls` gains `drafting: Set<String>`, `draftsOn: Bool`, `draft: (String) async -> String?`, `cancelDraft: (String) -> Void`; on a non-nil return, register one undo on `@Environment(\.undoManager)` that restores it through `edit`), `Canvas.swift:494-512` (wire them)
- Modify: `app/Sources/WakilApp/SettingsPane.swift:984` (third `quickTaskSwitchRow("Commit drafts", hint: …, on: tree.org.commitDrafts, key: .commitDrafts)`)

**Interfaces:**
- Consumes: Tasks 1–4's `editorLineSpans`, `editorRangesTouchChange`, `changesStageRanges` / `changesUnstageRanges`, `changesDraft`, `changesDrafting`, `changesCancelDraft`, `commitDraftsEnabled`, `OrganisationSwitch.commitDrafts`.

WakilApp has no test target. Its proof is the build, the full suite, and a look at the running app (Cover writes the e2e checks).

- [ ] **Step 1: Implement** the files above. ✨ is hidden when `draftsOn` is false. While drafting it shows a spinner with ✕ on hover, which calls `cancelDraft`. Focus stays in the box (Rule 3/6). The diff header button carries the identifiers from Global Constraints and shows its own spinner while `changesInFlight` holds the root (Rule 5).
- [ ] **Step 2: Run** `make app-test` (it builds WakilApp). Expected: PASS.
- [ ] **Step 3: Look at it.** Run `make app-bundle`, open the bundle on a scratch repository under `.scratch/3a-ii-b/`, and check each of the following:
  - Drag over two of three added lines in a Changes diff, then Stage Selected Ranges: `git diff --cached` shows just those two.
  - The right-click entry does the same.
  - In a Staged tab, Unstage Selected Ranges removes one line from `git diff --cached`.
  - ✨ fills the box; ⌘Z restores the earlier text.
  - Switching Commit drafts off hides ✨.
- [ ] **Step 4: Commit** `git commit -m "3a-ii-b: Stage/Unstage Selected Ranges and ✨ in the app"`.

### Task 6: Charter records

**Files:**
- Modify: `docs/wakil/decisions.md:1436` (Decision 42: move *commit drafts* from the candidates to built in 3a-ii-b, with its switch), `:1465-1466` (Decision 43: "**Stage Selected Ranges** in the diff tab came in 3a-ii-b, with Unstage, through the same `git_stage_hunk` and guard")
- Modify: `docs/wakil/north-star.md` §8 row 3a-ii-b: *Delivers* gains "and Unstage". `Met` is left for the walk.

- [ ] **Step 1: Edit** the three places above. Run `make docs-check`. Expected: PASS.
- [ ] **Step 2: Commit** `git commit -m "3a-ii-b: charter records"`.

**After the plan:** `superpowers:requesting-code-review` on the branch, then Cover (the e2e auditor, `docs/agents/e2e.md`), then the runbook `docs/wakil/phase-3a-ii-b-acceptance.md` for the operator's walk.
