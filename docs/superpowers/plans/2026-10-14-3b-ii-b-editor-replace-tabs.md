# 3b-ii-b: replace across the project, reveal, tab move and middle-click close — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Search view gains a Replace field with an inline preview, *Replace All* and *Replace in
this file* (open tabs edited in their buffers, every other covered file written, one in-memory undo);
the Files view gains a reveal button and a ⌘K command; tabs move by dragging within their strip and
close on a middle-click — all of it drivable by the agent through four new actions.

**Architecture:**
- **Go replaces.** `wakil-files` gains `files_replace_text` (read-only, batched: the preview and the
  open tabs' buffers) and `files_replace` (the write: the files `SearchFiles` walks, every match,
  skipping the open tabs, atomic per file, answering the original text and mtime of each file, and a
  resume cursor so a caller can stop between calls). One pattern compiler, `searchPattern`, serves
  search and replace, line by line.
- **WakilKit decides.** `EditorReplace.swift` holds the replace state (in the pane's
  `EditorSearchState`) and the pure helpers. `EditorActions.swift` gains `editor_replace`,
  `editor_replace_undo`, `editor_move_tab` and `editor_tree_reveal`; `editor_search` gains the Replace
  field (`replace`) and recomputes the preview. `EditorTabs.swift` gains the tab-move and drop-target
  rules. `WindowModel` gains the reveal flow and the middle-click close; the ⌘K catalog gains the
  reveal command.
- **WakilApp draws.** `EditorColumn` draws the field, the struck-through and violet preview, the
  buttons, the result line and the reveal button; `EditorPane` draws the tab drag with its drop line
  and catches the middle button through an `NSView` overlay.

**Tech Stack:**
- Go 1.x with `modelcontextprotocol/go-sdk` (fork); Go `regexp` (`Expand`).
- Swift 6.4 in language mode 6, Swift Testing, Observation, SwiftUI, AppKit.

**Spec:** `docs/superpowers/specs/2026-10-14-3b-ii-b-editor-replace-tabs-design.md` (read it with this
plan; it is the authority).

## Global Constraints

These are copied from the spec; every task's requirements include them.

**Replace**
- A **▸ toggle** beside the Search view's query line opens a **Replace** field under it. The field
  keeps its text when it is closed and opened again (Rule 2). Opening the toggle focuses the field
  (Rule 3).
- **The preview:** while the field holds text, each result line shows the match struck through and
  the replacement after it in violet. An empty field with the toggle open previews deleting the
  matches. With `.*` on, `$1`, `${name}` and `$$` work as Go's `regexp.Expand` reads them.
- The preview sends every shown result line to `files_replace_text` **in one call, 250 ms after the
  Replace field or the results change**. Only the 2,000 shown lines are previewed; Replace All still
  replaces past them.
- **Two buttons:** *Replace All* in the Search view's header, and *Replace in this file* on each file
  group's header (shown on hover and when the group is selected). **Neither asks first** (Rule 1).
- At the press, Go **searches again** and replaces **every** match — past the 2,000 the view shows —
  in exactly the files the search covers: ignored files, the heavy folders, binary files and files
  over 2 MB are skipped, as search skips them.
- **Open tabs are edited, not written:** a file open in any editor pane of the window gets the
  replacement in its buffer (dirty, ⌘Z undoes it); its file on disk is not touched. Every other file
  is written to disk, atomically.
- **While it runs**, the tick and *Cancel* show (Rules 4, 5), and both buttons are disabled.
- **After it runs**, one line: *Replaced 37 in 12 files · Undo replace*, then the search runs again.
  A file that could not be written is listed under that line with its error whole (Rule 8).
- **Undo replace** restores every file the replace wrote, only while that file's modification time is
  unchanged; a file changed since is listed as *"changed since the replace — left as it is"*. Buffer
  edits are not part of it. One undo is kept — the latest replace's — in memory for the window's life.
- A replacement that leaves the text the same writes nothing and counts nothing.

**Reveal**
- An icon button in the Files header, and a palette command, *Reveal Active File in Tree*.
- It opens every folder above the active tab's file, then selects that row and scrolls it into view.
  The keyboard stays where it was (Rule 6).
- **Disabled** when the pane has no file tab in front, with a tooltip saying so. **Never automatic.**

**Tabs**
- **Drag** a tab along its own pane's strip; a violet line shows where it will drop. The tab that was
  active stays active. The order is the pane's saved tab order, so it comes back after a relaunch. A
  drag that ends outside the strip, or on the tab's own place, changes nothing. **Within one pane only.**
- **A middle-click** on a tab closes it through the same path ⌘W uses: a clean tab closes at once, a
  dirty one gets 3b-i's Save / Don't Save / Cancel prompt.

**Actions (Invariant 2)**

| Action | Kind | Params | Price |
|---|---|---|---|
| `editor_replace` | mutate | `pane?`, `replacement` (may be empty), `file?` (absolute: one file), `cancel?` | *allow* everywhere (Decision 39) |
| `editor_replace_undo` | mutate | `pane?` | *allow* everywhere |
| `editor_tree_reveal` | control | `pane?`, `path?` (default: the active file) — opens folders only | — |
| `editor_move_tab` | control | `pane?`, `from`, `to` (0-based, strip order) | — |

- `read_pane`'s `search` gains `replace` (the field's text, or null while the toggle is closed),
  `replace_in_flight` and `last_replace` (`{replaced, files, failures: [{path, error}], undoable,
  undone, restored, cancelled}` or null).
- The refusals: a path outside the roots (Invariant 6), and an undo with nothing to undo.

**Process**
- Commits carry no `Co-Authored-By` or "Generated with Claude Code" lines (operator rule).
- Stacked PRs with gh-stack, one task per layer, on top of `yehia-khalil/3b-ii-b-spec`. Branches are
  `yehia-khalil/3b-ii-b-<n>-<slug>`.

**Test commands**
- Go:
  - `go test ./internal/wakilcore/ -run '<Name>'`
  - `go test ./cmd/wakil-files/`
- Swift, filtered: `cd app && ../scripts/swift-test.sh --filter '<regex>'`.
- Swift, full: `make build && make app-test`. The controller runs this, never a subagent:
  `make app-test` does not build Go.
- Docs: `make docs-check`.

**Toolchain and layering traps**
- Under the Swift 6.4 toolchain, `map`, `flatMap` and key paths over `[any PaneKind.Type]` crash
  SILGen: write plain loops (CONTRIBUTING.md, "Two traps").
- `#expect(await a == x && await b == y)` does not compile: the right side of `&&` is an autoclosure
  that cannot `await`. One `#expect` per awaited read.
- Layering, from `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`, which is shrink-only:
  `Layout` and `Command` must not use `Editor`. No task adds a link to that file
  (`CommandCatalog` reads a `Bool` from `PaletteContext`, never an `Editor` type).

## Review Focus

Five inputs the spec implies and no spec-level test exercises, most likely first.

1. **The operator types in an open tab while the replace edits that tab.** Neither text may be lost:
   the edit is applied only to the text it was computed from, and a tab typed in meanwhile is
   replaced again from what it holds now. Pinned in Task 2 by
   `aBufferTypedInDuringTheReplaceIsReplacedAgainNotOverwritten`.
2. **A replacement holding `$` with `.*` off** (`$1`, `$$`, a price like `$5`). It must be written
   literally; only regex mode expands. Pinned in Task 1 by
   `TestReplaceTextLiteralReplacementIsNotExpanded`.
3. **A pattern with anchors, or one that can match nothing** (`^foo$`, `x*`), on a many-line file.
   Replace must mean what search found: line by line, empty matches never replaced, nothing across a
   line break. Pinned in Task 1 by `TestReplaceTextIsLineByLineLikeSearch`.
4. **A file with CRLF line endings.** The endings must survive the replace byte for byte. Pinned in
   Task 1 by `TestFilesReplaceKeepsCRLF`.
5. **A tab dragged across the active tab** (the active tab's index shifts). The same tab must stay
   active, never whichever tab lands on the old index. Pinned in Task 3 by
   `movingATabKeepsTheActiveTabTheSameTab`.

---

## Rulings on the spec (recorded once, here, and repeated in the task that applies each)

1. **Cancel stops between batches, not by cancelling the tool call.** The spec says a cancel reaches
   the tool call and stops it between files, and that what was written can be undone. Both cannot
   hold: `MCPClient.sendRequest` drops the reply of a cancelled call (`cancelPending` resumes it with
   `CancellationError`), so the files a cancelled `files_replace` wrote would never reach the undo.
   So `files_replace` takes `after` (a cursor) and `max_files`, stops a call after `max_files`
   written files **or 250 ms**, and answers `next`. WakilKit loops, runs each call in its own task
   (a cancel never cancels a call in flight), and checks the pane's cancel between calls. A cancel
   lands within one call: about 250 ms plus one file. Go's own context cancellation still stops a
   call between files and answers what it wrote (the spec's Go contract, tested).
2. **Cancel is `editor_replace {cancel: true}`, not a fifth action**, as 3b-ii ruled for search: Rule 4
   needs a Cancel, Invariant 2 needs it to dispatch, and the spec's table has no name for it.
3. **The Replace field reaches the pane through `editor_search {replace}`.** The field's text is in
   `read_pane`, so it must be state, and state changes only through an action; the spec names none.
   `replace: "<text>"` opens the toggle with that text, `replace: null` closes it (the text is kept);
   with no `query`, nothing is searched. The same call recomputes the preview.
4. **The preview's spans come from Go.** `files_replace_text` answers `{text, count, edits}` per text,
   `edits` being each replacement's UTF-16 span and text — one field more than the spec's
   `{text, count}`. Drawing *struck match + violet replacement* needs where each match was and what
   replaced it; diffing two lines cannot tell two nearby matches apart.
5. **`files_replace` also answers `skipped`**: the `skip` paths (open tabs) its walk covers. Only those
   tabs get a buffer edit, so a `.env` open in a tab is never replaced in when search skips `.env`.
6. **`files_replace`'s `only` filters the same walk.** "Replace in this file" is always a file the
   search listed; an `only` the walk does not cover (ignored, heavy, binary) replaces nothing.
7. **A read-only file fails before it is written.** `WriteFile`'s temp-and-rename replaces a `0444`
   file without complaint (rename needs only the folder). The spec says a read-only file fails with
   its error, so `files_replace` checks `access(W_OK)` first and lists `"<path> is not writable: …"`.
8. **Replace is line by line, empty matches skipped**, exactly as `SearchFiles` matches. `^`/`$` are a
   line's ends, and a pattern never spans `\n`.
9. **An empty query replaces nothing.** `editor_replace` with an empty Search query answers the
   pane's state and records nothing (the buttons are disabled then); it is not a refusal (Rule 7).
10. **The undo lives in the pane's snapshot** (`EditorSearchState.replace.last`), so it goes where the
    pane's tabs go: an org switch empties it with every pane (`paneCells`); a project switch hides it
    with that project's panes, and it is there again on switching back, mtime-guarded as ever. The
    spec's "a project switch drops the undo" is read as *it never acts across projects*, which this
    keeps.
11. **`last_replace` carries `undone`, `restored` and `cancelled` too.** After an undo the result line
    reads *Undid the replace in N files*, and the files left are the listed failures; after a cancel
    it reads *Replace cancelled · replaced N in M files*. The spec's four keys stay as specified.
12. **The reveal command is in ⌘K** (the palette's command list; ⌘P lists files). It is hidden, not
    disabled, without a file tab in front, as every ⌘K command is (`CommandCatalog`'s rule).
13. **`editor_tree_reveal` with no file tab and no `path`** answers 3b-i's `noTab` / `notAFile`
    errors, as `editor_goto` does with no tab: there is nothing to act on. Not a new refusal.
14. **Tab drag is a `DragGesture`, not a system drag session.** A system drag needs an exported
    `UTType` in the bundle and carries data out of the window; a tab never leaves its strip. A drop
    **over a tab** moves the dragged tab to that tab's index, wherever on the tab the pointer is (the
    usual tab-strip rule), and the violet line draws on the side of that tab away from the dragged
    one. A drop in a gap between tabs, or past either end, takes the slot there (before or after).
    Pre-flight F4: the first draft's "first tab whose middle is right of the pointer" depended on the
    harness hitting a tab's exact centre, which fractional tab widths make flaky.
15. **The persisted order after a relaunch is the walk's** (one check is one launch, `editor_restore`'s
    precedent in `uncoverable.tsv`); a unit test restores from the layout's saved order.

Pre-flight corrections (the controller's ruling: each is a plan defect, the spec is the authority):

- Pre-flight F1: `editor_search` applies `replace` whenever it is present (string opens, null closes) and returns early only when `query` is absent; with a `query` it falls through to `runSearch`, which refreshes the preview (ruling 3 read whole; test `searchWithBothAQueryAndAReplaceSetsTheFieldAndSearches`).
- Pre-flight F2: the skip list and the buffer edits cover every editor pane `PaneStore` holds, in every scope (`editorPanesInEveryScope`, `editorSnapshot(in:paneId:)`, `updateEditor(in:)`), so a dirty tab in another conversation's pane is edited in its buffer and its file is never written (spec, Open tabs; Decision 39; test `aDirtyTabInAScopeNotOnScreen…`).
- Pre-flight F3: the 250 ms batch clock starts after a root is listed (a resumed call re-lists its root), so a slow listing never cuts a call to one file; a `replaceAfterList` seam stands for the slow listing in `TestFilesReplaceTheBatchClockExcludesTheListing`.
- Pre-flight F4: a tab dropped over a tab moves to that tab's index, wherever on it (`editorTabDropTarget`), the line drawing on the side away from the dragged tab (`editorTabDropX`); gaps and ends keep the slot rule. The harness's drop no longer has to hit an exact centre (ruling 14 rewritten).
- Pre-flight F5: only file group headers change to `.contain` (`children: root ? .combine : .contain`); root headers keep `.combine`, and Task 5 Step 4 names `3b-ii-search.jsonl`, which clicks a root header, as the regression check.
- Pre-flight F6: option chosen, an undo is cancellable. It sets `undoing` (with `inFlight`) so the tick reads "undoing", and `editor_replace {cancel}` stops it before its next file, listing the rest as `EditorReplaceFailure.stopped`; `cancelRequested` and `undoing` are cleared when it ends (test `undoShowsItsOwnStateAndItsCancelStopsItBetweenFiles`).
- Pre-flight F7: `replaceInBuffers` collects `[path: count]` across panes and takes each path's count once, so a file open in two panes adds its matches once (test `aFileOpenInTwoPanesIsCountedOnce`).
- Pre-flight F8: Task 5 also fixes the Invariant 6 note's first sentence: writes go through `files_write` (and, since 3b-ii-b, `files_replace`).
- Pre-flight F9: the seed haystack's extra file is `bulk/zz-marker.txt` holding `replace-marker-qz7` (no other check's query matches it, `needle` did); the seed test's pin becomes `searchBulkFiles+1`, asserts the file by name, and runs the marker's content through the query-hygiene loop.

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `internal/wakilcore/files.go`, `files_test.go` | 1 | `ReplaceText`, `ReplaceEdits`, `ReplaceTexts`, `ReplaceFiles` |
| `cmd/wakil-files/main.go`, `main_test.go`, `schema_test.go` | 1 | `files_replace_text`, `files_replace` |
| `docs/architecture/go.md` | 1 | `### wakil-files` tool list |
| `app/Sources/WakilKit/Editor/EditorReplace.swift` (new) | 2 | replace state, results, undo records, pure helpers, reply parsers |
| `app/Sources/WakilKit/Editor/EditorSearch.swift` | 2 | `EditorSearchState.replace` |
| `app/Sources/WakilKit/Editor/EditorPaneKind.swift` | 2 | `read_pane`'s three new `search` keys |
| `app/Sources/WakilKit/Editor/PaneStore+Editor.swift` | 2 | wake the window when a replace starts or ends; every scope's editor panes (the skip list) |
| `app/Sources/WakilKit/Editor/EditorActions.swift` | 2, 3 | `editor_replace`, `editor_replace_undo`, `editor_search {replace}`; `editor_move_tab`, `editor_tree_reveal` |
| `app/Sources/WakilKit/MCP/MCPServer.swift` | 2 | `read_pane`'s description |
| `app/Sources/WakilKit/Editor/EditorTabs.swift` | 3 | `editorMovingTab`, `editorTabDropTarget`, `EditorTabDrop`, `editorTabDropX` |
| `app/Sources/WakilKit/App/WindowModel.swift` | 3 | `revealActiveFileInTree`, `editorTreeRevealRequest`, `closeEditorTab`, ⌘K's reveal |
| `app/Sources/WakilKit/Command/CommandCatalog.swift` | 3 | `editor.reveal`, `PaletteContext.editorActiveIsFile` |
| `app/Sources/WakilApp/EditorColumn.swift`, `EditorPane.swift`, `Canvas.swift`, `EditorMiddleClick.swift` (new) | 4 | drawing |
| `e2e/checks/seeded/3b-ii-b-*.jsonl`, `e2e/driver/seedgit.go`, `seed_test.go`, `e2e/checks/uncoverable.tsv`, docs | 5 | checks, runbook, charter |

Test files:
- `internal/wakilcore/files_test.go`, `cmd/wakil-files/main_test.go`, `schema_test.go`;
- `app/Tests/WakilKitTests/`: `EditorReplaceTests.swift` (new), `EditorReplaceActionsTests.swift`
  (new), `EditorTabMoveRevealTests.swift` (new), and the existing `EditorTestSupport.swift`
  (FakeFiles), `EditorTabsTests.swift`, `EditorReadPaneTests.swift`, `WindowModelEditorTests.swift`,
  `CommandCatalogTests.swift`, `AppWiringTests.swift`, `WindowModelPaletteTests.swift`,
  `InvalidationContractTests.swift`.

---

### Task 1: `files_replace_text` and `files_replace` (PR 1)

**Files:**
- Modify: `internal/wakilcore/files.go`, `internal/wakilcore/files_test.go`
- Modify: `cmd/wakil-files/main.go`, `cmd/wakil-files/main_test.go`, `cmd/wakil-files/schema_test.go`
- Modify: `docs/architecture/go.md` (the `### wakil-files` section)

**Interfaces:**
- Consumes: `searchPattern`, `SearchQuery`, `ListFiles`, `ConfineFilePath`, `realRoots`, `outsideRoots`,
  `WriteFile`, `FileCap`, `UserError` (all in `internal/wakilcore`).
- Produces (Go):
  - `ReplaceEdit{Start, End int; Text string}` — JSON `start`, `end` (UTF-16 offsets into the whole
    text), `text`.
  - `ReplaceEdits(text string, q SearchQuery, replacement string) ([]ReplaceEdit, error)`
  - `ReplaceText(text string, q SearchQuery, replacement string) (string, int, error)` — the spec's
    signature: new text and count.
  - `ReplacedText{Text string; Count int; Edits []ReplaceEdit}`, `ReplaceTextsResult{Results []ReplacedText}`
    and `ReplaceTexts(texts []string, q SearchQuery, replacement string) (ReplaceTextsResult, error)`.
  - `ReplaceOptions{Roots []string; Only string; Skip []string; After string; MaxFiles int}`
  - `ReplacedFile{Path string; Count int; Original string; Mtime int64}`,
    `ReplaceFailure{Path, Error string}`, and
    `ReplaceResult{Files []ReplacedFile; Failures []ReplaceFailure; Skipped []string; TruncatedFiles,
    Cancelled bool; Next string}` with JSON keys `files`, `failures`, `skipped`, `truncated_files`,
    `cancelled`, `next`. Every slice is non-nil.
  - `ReplaceFiles(ctx, roots []string, q SearchQuery, replacement string, o ReplaceOptions) (ReplaceResult, error)`
  - `var ReplaceBatchTime = 250 * time.Millisecond`, `const ReplaceBatchBytes = 8 << 20`.
    `ReplaceBatchTime` times file handling only, never the listing a resumed call re-runs (pre-flight F3).
- Produces (MCP):
  - `files_replace_text {texts[], query, case?, word?, regex?, replacement}` → `{results: [{text, count, edits}]}`.
  - `files_replace {roots?, query, case?, word?, regex?, replacement, only?, skip?, after?, max_files?}`
    → `{files: [{path, count, original, mtime}], failures: [{path, error}], skipped, truncated_files,
    cancelled, next}`. A file's `path` is its root **as passed** joined with its relative path, so it
    matches the app's roots and tabs. `next` is `"<root index>/<relative path>"`, or `""` when the
    walk is done.

**Rulings that apply here:** 1 (the cursor and the 250 ms bound), 4 (`edits`), 5 (`skipped`), 6
(`only` filters the walk), 7 (`access(W_OK)`), 8 (line by line).

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/files_test.go`:

```go
func TestReplaceTextSwitches(t *testing.T) {
	cases := []struct {
		text string
		q    SearchQuery
		with string
		want string
		n    int
	}{
		{"Foo foo FOO", SearchQuery{Query: "foo"}, "x", "x x x", 3},
		{"Foo foo FOO", SearchQuery{Query: "foo", Case: true}, "x", "Foo x FOO", 1},
		{"foo food", SearchQuery{Query: "foo", Word: true}, "x", "x food", 1},
		{"a.b axb", SearchQuery{Query: "a.b"}, "x", "x axb", 1}, // literal: the dot is a dot
		{"nothing here", SearchQuery{Query: "foo"}, "x", "nothing here", 0},
		{"foo bar", SearchQuery{Query: "foo "}, "", "bar", 1}, // an empty replacement deletes
	}
	for _, c := range cases {
		got, n, err := ReplaceText(c.text, c.q, c.with)
		if err != nil || got != c.want || n != c.n {
			t.Fatalf("%+v: got %q, %d, %v", c.q, got, n, err)
		}
	}
}

func TestReplaceTextRegexExpandsGroups(t *testing.T) {
	cases := []struct{ text, query, with, want string }{
		{"id=7 id=8", `id=(\d)`, `n$1`, "n7 n8"},
		{"id=7", `(?P<k>\w+)=(?P<v>\d)`, `${v}:${k}`, "7:id"},
		{"cost 5", `(\d)`, `$$$1`, "cost $5"},
	}
	for _, c := range cases {
		got, _, err := ReplaceText(c.text, SearchQuery{Query: c.query, Regex: true}, c.with)
		if err != nil || got != c.want {
			t.Fatalf("%s → %s: got %q, %v", c.query, c.with, got, err)
		}
	}
}

// Review Focus 2: with .* off, the replacement is text, never a template.
func TestReplaceTextLiteralReplacementIsNotExpanded(t *testing.T) {
	got, n, err := ReplaceText("a b", SearchQuery{Query: "a"}, "$1$$")
	if err != nil || got != "$1$$ b" || n != 1 {
		t.Fatalf("got %q, %d, %v", got, n, err)
	}
}

// Review Focus 3: a pattern means what search found — per line, never across one, empty matches never.
func TestReplaceTextIsLineByLineLikeSearch(t *testing.T) {
	if got, n, _ := ReplaceText("foo\nfoo\n", SearchQuery{Query: `^foo$`, Regex: true}, "x"); got != "x\nx\n" || n != 2 {
		t.Fatalf("anchors: got %q, %d", got, n)
	}
	if got, n, _ := ReplaceText("ab\n", SearchQuery{Query: `x*`, Regex: true}, "-"); got != "ab\n" || n != 0 {
		t.Fatalf("empty matches: got %q, %d", got, n)
	}
	if got, n, _ := ReplaceText("fo\nof\n", SearchQuery{Query: `o\no`, Regex: true}, "-"); got != "fo\nof\n" || n != 0 {
		t.Fatalf("across a line: got %q, %d", got, n)
	}
}

func TestReplaceTextLeavingTheTextTheSameCountsNothing(t *testing.T) {
	if got, n, _ := ReplaceText("foo", SearchQuery{Query: "foo"}, "foo"); got != "foo" || n != 0 {
		t.Fatalf("same: got %q, %d", got, n)
	}
	if got, n, _ := ReplaceText("FOO", SearchQuery{Query: "foo"}, "foo"); got != "foo" || n != 1 {
		t.Fatalf("case: got %q, %d", got, n)
	}
}

func TestReplaceEditsAreUTF16Offsets(t *testing.T) {
	// "😀 foo\n" is 2 + 1 units before foo, then foo (3) and "\n": line 2 starts at 7, and "حجز " is 4.
	edits, err := ReplaceEdits("😀 foo\nحجز foo", SearchQuery{Query: "foo"}, "bar")
	want := []ReplaceEdit{{Start: 3, End: 6, Text: "bar"}, {Start: 11, End: 14, Text: "bar"}}
	if err != nil || !slices.Equal(edits, want) {
		t.Fatalf("got %+v, %v", edits, err)
	}
}

func TestReplaceTextAnInvalidRegexIsGosOwnError(t *testing.T) {
	if _, _, err := ReplaceText("x", SearchQuery{Query: "book(", Regex: true}, "y"); err == nil ||
		!strings.Contains(err.Error(), "missing closing )") {
		t.Fatalf("got %v", err)
	}
}

func readText(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestFilesReplaceWritesEveryMatchPastTheSearchCap(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "many.txt")
	write(t, p, strings.Repeat("x\n", SearchCap+5))
	r, err := ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "x"}, "y", ReplaceOptions{})
	if err != nil || len(r.Files) != 1 || r.Files[0].Count != SearchCap+5 || r.Next != "" {
		t.Fatalf("got %+v, %v", r, err)
	}
	if readText(t, p) != strings.Repeat("y\n", SearchCap+5) {
		t.Fatal("not every match was replaced")
	}
}

func TestFilesReplaceSkipsWhatSearchSkips(t *testing.T) {
	a, b := searchFixture(t)
	write(t, filepath.Join(a, "bin.dat"), "bookingId\x00")
	write(t, filepath.Join(b, "big.txt"), "bookingId\n"+strings.Repeat("y", FileCap))
	r, err := ReplaceFiles(context.Background(), []string{a, b}, SearchQuery{Query: "bookingId"}, "booking_id", ReplaceOptions{})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, f := range r.Files {
		got = append(got, fmt.Sprintf("%s:%d", filepath.Base(filepath.Dir(f.Path))+"/"+filepath.Base(f.Path), f.Count))
	}
	if strings.Join(got, ",") != "a/Booking.php:2,b/routes.ts:1" {
		t.Fatalf("got %v", got)
	}
	if readText(t, filepath.Join(a, ".env")) != "bookingId=secret\n" || !strings.HasPrefix(readText(t, filepath.Join(b, "big.txt")), "bookingId") {
		t.Fatal("an ignored or over-cap file was written")
	}
}

func TestFilesReplaceIsConfinedToTheRoots(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "secret.txt"), "needle\n")
	if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(a, "link.txt")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(a, "ok.txt"), "needle\n")
	q := SearchQuery{Query: "needle"}
	r, err := ReplaceFiles(context.Background(), []string{a}, q, "pin", ReplaceOptions{})
	if err != nil || len(r.Files) != 1 || readText(t, filepath.Join(outside, "secret.txt")) != "needle\n" {
		t.Fatalf("got %+v, %v", r, err)
	}
	for _, o := range []ReplaceOptions{{Only: filepath.Join(a, "link.txt")}, {Roots: []string{outside}}} {
		if _, err := ReplaceFiles(context.Background(), []string{a}, q, "pin", o); err == nil ||
			!strings.Contains(err.Error(), "Invariant 6") {
			t.Fatalf("%+v: got %v", o, err)
		}
	}
}

func TestFilesReplaceLeavesSkippedFilesReportsThemAndOnlyNamesOne(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	two := filepath.Join(a, "2.txt")
	r, err := ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "old"}, "new",
		ReplaceOptions{Skip: []string{two, "/nowhere/x"}})
	if err != nil || len(r.Files) != 2 || !slices.Equal(r.Skipped, []string{two}) || readText(t, two) != "old\n" {
		t.Fatalf("got %+v, %v", r, err)
	}
	r, err = ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "old"}, "new", ReplaceOptions{Only: two})
	if err != nil || len(r.Files) != 1 || r.Files[0].Path != two || readText(t, two) != "new\n" {
		t.Fatalf("only: got %+v, %v", r, err)
	}
}

func TestFilesReplaceStopsBetweenFilesWhenCancelled(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	ctx, cancel := context.WithCancel(context.Background())
	replaceAfterWrite = cancel
	t.Cleanup(func() { replaceAfterWrite = nil })
	r, err := ReplaceFiles(ctx, []string{a}, SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	if err != nil || !r.Cancelled || len(r.Files) != 1 || r.Files[0].Path != filepath.Join(a, "1.txt") {
		t.Fatalf("got %+v, %v", r, err)
	}
	if readText(t, filepath.Join(a, "2.txt")) != "old\n" {
		t.Fatal("a file after the cancel was written")
	}
}

func TestFilesReplaceListsAFailedWriteAndGoesOn(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	two := filepath.Join(a, "2.txt")
	if err := os.Chmod(two, 0o444); err != nil {
		t.Fatal(err)
	}
	r, err := ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	if err != nil || len(r.Files) != 2 || len(r.Failures) != 1 || r.Failures[0].Path != two ||
		!strings.Contains(r.Failures[0].Error, "is not writable") {
		t.Fatalf("got %+v, %v", r, err)
	}
	if readText(t, two) != "old\n" || readText(t, filepath.Join(a, "3.txt")) != "new\n" {
		t.Fatal("the failed file changed, or the next one was not written")
	}
}

func TestFilesReplaceAnswersTheOriginalAndMtimeAndKeepsTheMode(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "run.sh")
	write(t, p, "echo old\n")
	if err := os.Chmod(p, 0o755); err != nil {
		t.Fatal(err)
	}
	r, err := ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	st, serr := os.Stat(p)
	if err != nil || serr != nil || len(r.Files) != 1 || r.Files[0].Original != "echo old\n" ||
		r.Files[0].Mtime != st.ModTime().UnixNano() || st.Mode().Perm() != 0o755 {
		t.Fatalf("got %+v, %v, mode %v", r, err, st.Mode())
	}
}

// Review Focus 4.
func TestFilesReplaceKeepsCRLF(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "win.txt")
	write(t, p, "old one\r\nold two\r\n")
	if _, err := ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "old"}, "new", ReplaceOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := readText(t, p); got != "new one\r\nnew two\r\n" {
		t.Fatalf("got %q", got)
	}
}

func TestFilesReplaceInBatchesResumesAfterNext(t *testing.T) {
	a, b, _ := filesRoots(t)
	for _, p := range []string{filepath.Join(a, "1.txt"), filepath.Join(a, "2.txt"), filepath.Join(b, "3.txt")} {
		write(t, p, "old\n")
	}
	var got []string
	after, calls := "", 0
	for {
		r, err := ReplaceFiles(context.Background(), []string{a, b}, SearchQuery{Query: "old"}, "new",
			ReplaceOptions{After: after, MaxFiles: 1})
		if err != nil {
			t.Fatal(err)
		}
		calls++
		for _, f := range r.Files {
			got = append(got, filepath.Base(f.Path))
		}
		if r.Next == "" || calls > 10 {
			break
		}
		after = r.Next
	}
	if strings.Join(got, ",") != "1.txt,2.txt,3.txt" || calls != 3 {
		t.Fatalf("got %v in %d calls", got, calls)
	}
}

// Pre-flight F3: a resumed call re-lists its root, and the listing must not spend the batch's time.
func TestFilesReplaceTheBatchClockExcludesTheListing(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt", "4.txt", "5.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	defer func(d time.Duration) { ReplaceBatchTime = d }(ReplaceBatchTime)
	ReplaceBatchTime = 50 * time.Millisecond
	replaceAfterList = func() { time.Sleep(120 * time.Millisecond) } // a slow listing, longer than the budget
	t.Cleanup(func() { replaceAfterList = nil })
	r, err := ReplaceFiles(context.Background(), []string{a}, SearchQuery{Query: "old"}, "new", ReplaceOptions{MaxFiles: 50})
	if err != nil || len(r.Files) != 5 || r.Next != "" {
		t.Fatalf("got %d files, next %q, %v: the listing spent the budget", len(r.Files), r.Next, err)
	}
}
```

Append to `cmd/wakil-files/main_test.go`:

```go
func TestFilesReplaceTextIsServed(t *testing.T) {
	setupProject(t, `"dev":{"databases":[]}`, "")
	res, out := callFiles(t, "files_replace_text", map[string]any{
		"texts": []any{"a foo", "none"}, "query": "foo", "replacement": "bar"})
	if res.IsError {
		t.Fatalf("failed: %+v", res.Content[0])
	}
	results, _ := out["results"].([]any)
	first, _ := results[0].(map[string]any)
	if len(results) != 2 || first["text"] != "a bar" || first["count"] != float64(1) {
		t.Fatalf("got %v", out)
	}
}

func TestFilesReplaceIsServedAndConfined(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "n.txt")
	if err := os.WriteFile(p, []byte("a needle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, out := callFiles(t, "files_replace", map[string]any{"query": "needle", "replacement": "pin"})
	files, _ := out["files"].([]any)
	if res.IsError || len(files) != 1 {
		t.Fatalf("got %v", out)
	}
	if b, _ := os.ReadFile(p); string(b) != "a pin\n" {
		t.Fatalf("disk %q", b)
	}
	res, _ = callFiles(t, "files_replace", map[string]any{"query": "x", "replacement": "y", "only": "/etc/hosts"})
	if !res.IsError || !strings.Contains(res.Content[0].(*mcp.TextContent).Text, "Invariant 6") {
		t.Fatalf("outside the roots: %+v", res.Content)
	}
}
```

`schema_test.go`:

```go
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{"files_list", "files_list_dir", "files_search", "files_replace_text", "files_replace", "files_read", "files_write"})
```

- [ ] **Step 2: Run them; they fail**

Run: `go test ./internal/wakilcore/ -run 'TestReplace|TestFilesReplace' && go test ./cmd/wakil-files/`
Expected: FAIL — `undefined: ReplaceText`, `undefined: ReplaceFiles`, `undefined: replaceAfterWrite`, `undefined: replaceAfterList`,
unknown tool `files_replace_text`.

- [ ] **Step 3: Implement**

In `internal/wakilcore/files.go`, add `"fmt"`, `"strconv"`, `"syscall"` and `"time"` to the imports,
then after `SearchFiles`:

```go
// ReplaceEdit is one replacement in a text: the UTF-16 span [Start, End) it replaces, as Monaco
// counts, and what goes there (3b-ii-b).
type ReplaceEdit struct {
	Start int    `json:"start"`
	End   int    `json:"end"`
	Text  string `json:"text"`
}

type byteEdit struct {
	start, end int
	text       string
}

// replaceByteEdits finds re's matches the way SearchFiles does — line by line, empty matches
// skipped — and what each becomes: replacement expanded by regexp.Expand when expand ($1, ${name},
// $$), taken literally otherwise. A match whose replacement equals it is no edit (spec: a
// replacement that leaves the text the same counts nothing).
func replaceByteEdits(re *regexp.Regexp, text string, expand bool, replacement string) []byteEdit {
	var out []byteEdit
	off := 0
	for _, line := range strings.Split(text, "\n") {
		for _, m := range re.FindAllStringSubmatchIndex(line, -1) {
			if m[0] == m[1] {
				continue
			}
			with := replacement
			if expand {
				with = string(re.ExpandString(nil, replacement, line, m))
			}
			if with == line[m[0]:m[1]] {
				continue
			}
			out = append(out, byteEdit{start: off + m[0], end: off + m[1], text: with})
		}
		off += len(line) + 1
	}
	return out
}

func applyByteEdits(text string, edits []byteEdit) string {
	var b strings.Builder
	last := 0
	for _, e := range edits {
		b.WriteString(text[last:e.start])
		b.WriteString(e.text)
		last = e.end
	}
	b.WriteString(text[last:])
	return b.String()
}

func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

func utf16Edits(text string, edits []byteEdit) []ReplaceEdit {
	out := make([]ReplaceEdit, 0, len(edits))
	units, at := 0, 0
	for _, e := range edits {
		units += utf16Len(text[at:e.start])
		start := units
		units += utf16Len(text[e.start:e.end])
		at = e.end
		out = append(out, ReplaceEdit{Start: start, End: units, Text: e.text})
	}
	return out
}

// ReplaceEdits is every replacement ReplaceText would make in text, as UTF-16 spans.
func ReplaceEdits(text string, q SearchQuery, replacement string) ([]ReplaceEdit, error) {
	re, err := searchPattern(q)
	if err != nil {
		return nil, err
	}
	return utf16Edits(text, replaceByteEdits(re, text, q.Regex, replacement)), nil
}

// ReplaceText is text with every match of q replaced — the pattern SearchFiles compiles, line by
// line — and how many were (3b-ii-b).
func ReplaceText(text string, q SearchQuery, replacement string) (string, int, error) {
	re, err := searchPattern(q)
	if err != nil {
		return "", 0, err
	}
	edits := replaceByteEdits(re, text, q.Regex, replacement)
	return applyByteEdits(text, edits), len(edits), nil
}

type ReplacedText struct {
	Text  string        `json:"text"`
	Count int           `json:"count"`
	Edits []ReplaceEdit `json:"edits"`
}

type ReplaceTextsResult struct {
	Results []ReplacedText `json:"results"`
}

// ReplaceTexts is ReplaceText over each text, in order: the open tabs' buffers and the preview's
// lines, so both agree with what files_replace writes. It touches no file.
func ReplaceTexts(texts []string, q SearchQuery, replacement string) (ReplaceTextsResult, error) {
	re, err := searchPattern(q)
	if err != nil {
		return ReplaceTextsResult{}, err
	}
	out := ReplaceTextsResult{Results: make([]ReplacedText, 0, len(texts))}
	for _, t := range texts {
		edits := replaceByteEdits(re, t, q.Regex, replacement)
		out.Results = append(out.Results, ReplacedText{Text: applyByteEdits(t, edits), Count: len(edits), Edits: utf16Edits(t, edits)})
	}
	return out, nil
}

// ReplaceBatchTime bounds a batched files_replace call (MaxFiles > 0): it stops between files once
// this long has passed and at least one file was handled, so a caller looping on Next can stop
// between calls (3b-ii-b ruling 1). A var for tests.
var ReplaceBatchTime = 250 * time.Millisecond

// ReplaceBatchBytes bounds the originals one batched call answers, so a reply stays a few MB.
const ReplaceBatchBytes = 8 << 20

// replaceAfterWrite is a test seam, called after each file a replace writes.
var replaceAfterWrite func()

// replaceAfterList is a test seam, called right after a root is listed and before the batch clock
// starts: a test sleeps in it to stand for a slow listing.
var replaceAfterList func()

type ReplaceOptions struct {
	Roots    []string // the roots to walk, each a root of roots; every root when empty
	Only     string   // one file (absolute): only it, when the walk covers it
	Skip     []string // files left on disk (open tabs); those the walk covers come back in Skipped
	After    string   // a previous call's Next: resume after it
	MaxFiles int      // stop after writing this many, or ReplaceBatchTime (0: neither)
}

type ReplacedFile struct {
	Path     string `json:"path"`
	Count    int    `json:"count"`
	Original string `json:"original"`
	Mtime    int64  `json:"mtime"`
}

type ReplaceFailure struct {
	Path  string `json:"path"`
	Error string `json:"error"`
}

type ReplaceResult struct {
	Files          []ReplacedFile   `json:"files"`
	Failures       []ReplaceFailure `json:"failures"`
	Skipped        []string         `json:"skipped"`
	TruncatedFiles bool             `json:"truncated_files"`
	Cancelled      bool             `json:"cancelled"`
	Next           string           `json:"next"`
}

// ReplaceFiles writes every match of q, replaced, in the files SearchFiles walks (o.Roots, else
// every root): never ignored, heavy, binary or over-cap files, never past a link out of the roots,
// never a file in o.Skip. Each file is written whole and atomically (WriteFile), keeping its mode;
// one that cannot be written is listed and the rest go on (Rule 8). A cancelled ctx stops it between
// files with what it wrote. With MaxFiles it stops early and Next resumes it (3b-ii-b ruling 1).
func ReplaceFiles(ctx context.Context, roots []string, q SearchQuery, replacement string, o ReplaceOptions) (ReplaceResult, error) {
	re, err := searchPattern(q)
	if err != nil {
		return ReplaceResult{}, err
	}
	res := ReplaceResult{Files: []ReplacedFile{}, Failures: []ReplaceFailure{}, Skipped: []string{}}
	if q.Query == "" {
		return res, nil // ruling 9: an empty query replaces nothing
	}
	targets := roots
	if len(o.Roots) > 0 {
		real := realRoots(roots)
		for _, r := range o.Roots {
			rr, rerr := filepath.EvalSymlinks(r)
			if rerr != nil || !slices.Contains(real, rr) {
				return ReplaceResult{}, outsideRoots(r)
			}
		}
		targets = o.Roots
	}
	only := ""
	if o.Only != "" {
		p, _, cerr := ConfineFilePath(o.Only, roots, true)
		if cerr != nil {
			return ReplaceResult{}, cerr
		}
		only = p
	}
	skip := map[string]string{} // real path → the path as given
	for _, s := range o.Skip {
		if p, serr := filepath.EvalSymlinks(s); serr == nil {
			skip[p] = s
		}
	}
	afterRoot, afterRel := -1, ""
	if o.After != "" {
		i := strings.IndexByte(o.After, '/')
		n, aerr := -1, error(nil)
		if i > 0 {
			n, aerr = strconv.Atoi(o.After[:i])
		}
		if i <= 0 || aerr != nil {
			return ReplaceResult{}, UserError("files_replace: after " + o.After + " is not a cursor files_replace answered")
		}
		afterRoot, afterRel = n, o.After[i+1:]
	}
	var start time.Time // the batch clock: started after a root is listed, so a listing never spends it
	held, handled := 0, 0
	for ri, root := range targets {
		if ri < afterRoot {
			continue
		}
		l, lerr := ListFiles(ctx, root, roots)
		if lerr != nil {
			if ctx.Err() != nil {
				res.Cancelled = true
				return res, nil
			}
			res.Failures = append(res.Failures, ReplaceFailure{Path: root, Error: lerr.Error()})
			continue
		}
		res.TruncatedFiles = res.TruncatedFiles || l.Truncated
		if replaceAfterList != nil {
			replaceAfterList()
		}
		start = time.Now() // pre-flight F3: each resumed call re-lists its root; only file handling is timed
		for _, rel := range l.Files {
			if ri == afterRoot && rel <= afterRel {
				continue
			}
			if ctx.Err() != nil {
				res.Cancelled = true
				return res, nil
			}
			if o.MaxFiles > 0 && handled > 0 &&
				(len(res.Files) >= o.MaxFiles || held >= ReplaceBatchBytes || time.Since(start) >= ReplaceBatchTime) {
				return res, nil // Next names the last file handled
			}
			handled++
			res.Next = fmt.Sprintf("%d/%s", ri, rel)
			p, _, cerr := ConfineFilePath(filepath.Join(l.Root, filepath.FromSlash(rel)), roots, true)
			if cerr != nil || (only != "" && p != only) {
				continue
			}
			if given, ok := skip[p]; ok {
				res.Skipped = append(res.Skipped, given)
				continue
			}
			info, serr := os.Stat(p)
			if serr != nil || !info.Mode().IsRegular() || info.Size() > FileCap {
				continue
			}
			data, rerr := os.ReadFile(p)
			if rerr != nil || bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
				continue
			}
			text := string(data)
			edits := replaceByteEdits(re, text, q.Regex, replacement)
			if len(edits) == 0 {
				continue
			}
			path := filepath.Join(root, filepath.FromSlash(rel))
			// Ruling 7: temp-and-rename would replace a read-only file; the spec says it fails.
			if aerr := syscall.Access(p, 2 /* W_OK */); aerr != nil {
				res.Failures = append(res.Failures, ReplaceFailure{Path: path, Error: path + " is not writable: " + aerr.Error()})
				continue
			}
			w, werr := WriteFile(p, applyByteEdits(text, edits), false, roots)
			if werr != nil {
				res.Failures = append(res.Failures, ReplaceFailure{Path: path, Error: werr.Error()})
				continue
			}
			res.Files = append(res.Files, ReplacedFile{Path: path, Count: len(edits), Original: text, Mtime: w.Mtime})
			held += len(text)
			if replaceAfterWrite != nil {
				replaceAfterWrite()
			}
		}
	}
	res.Next = ""
	return res, nil
}
```

In `cmd/wakil-files/main.go`, the arguments:

```go
type replaceTextArg struct {
	Texts       []string `json:"texts" jsonschema:"the texts to replace in, each whole; answered in order"`
	Query       string   `json:"query" jsonschema:"the text to find"`
	Case        bool     `json:"case,omitempty" jsonschema:"true for a case-sensitive match"`
	Word        bool     `json:"word,omitempty" jsonschema:"true to match whole words only"`
	Regex       bool     `json:"regex,omitempty" jsonschema:"true to read query as a Go regular expression"`
	Replacement string   `json:"replacement" jsonschema:"what each match becomes; with regex, $1, ${name} and $$ expand as Go's regexp.Expand reads them"`
}
type replaceArg struct {
	Roots       []string `json:"roots,omitempty" jsonschema:"roots to replace in (absolute, each a root of the active project); all of them when empty"`
	Query       string   `json:"query" jsonschema:"the text to find"`
	Case        bool     `json:"case,omitempty" jsonschema:"true for a case-sensitive match"`
	Word        bool     `json:"word,omitempty" jsonschema:"true to match whole words only"`
	Regex       bool     `json:"regex,omitempty" jsonschema:"true to read query as a Go regular expression"`
	Replacement string   `json:"replacement" jsonschema:"what each match becomes; with regex, $1, ${name} and $$ expand as Go's regexp.Expand reads them"`
	Only        string   `json:"only,omitempty" jsonschema:"one file (absolute): replace in it alone"`
	Skip        []string `json:"skip,omitempty" jsonschema:"files (absolute) to leave on disk; those the search covers come back in skipped"`
	After       string   `json:"after,omitempty" jsonschema:"a previous call's next: resume after it"`
	MaxFiles    int      `json:"max_files,omitempty" jsonschema:"stop after writing this many files, or after 250 ms; next resumes"`
}
```

and the tools, after `files_search`:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "files_replace_text", Description: "Read-only. Each of texts with every match of query replaced — the pattern files_search uses, line by line — answering per text its new text, count and edits (each replacement's UTF-16 span start..end in the old text, and its text). Touches no file."},
		func(_ context.Context, _ *mcp.CallToolRequest, a replaceTextArg) (*mcp.CallToolResult, wakilcore.ReplaceTextsResult, error) {
			r, err := wakilcore.ReplaceTexts(a.Texts, wakilcore.SearchQuery{Query: a.Query, Case: a.Case, Word: a.Word, Regex: a.Regex}, a.Replacement)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.ReplaceTextsResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_replace", Description: "Writes every match of query, replaced, in the files files_search covers (ignored, heavy, binary and over-2 MB files skipped), each file whole and atomically, keeping its mode. Files in skip are left on disk and those covered are listed in skipped; only names one file. Answers each written file's path, count, original text and mtime, the files that failed with their error, and truncated_files. With max_files it stops early and next resumes it; a cancelled call stops between files with what it wrote (cancelled). Confined to the active project's roots (Invariant 6, Decision 36, Decision 39)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a replaceArg) (*mcp.CallToolResult, wakilcore.ReplaceResult, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.ReplaceResult{}, nil
			}
			r, err := wakilcore.ReplaceFiles(ctx, rs, wakilcore.SearchQuery{Query: a.Query, Case: a.Case, Word: a.Word, Regex: a.Regex},
				a.Replacement, wakilcore.ReplaceOptions{Roots: a.Roots, Only: a.Only, Skip: a.Skip, After: a.After, MaxFiles: a.MaxFiles})
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.ReplaceResult{}, nil
			}
			return nil, r, nil
		})
```

`docs/architecture/go.md`, `### wakil-files`: "Five tools" becomes "Seven tools", and after the
`files_search` bullet:

```markdown
- `files_replace_text` — read-only: each of `texts` with every match replaced (the `files_search`
  pattern, line by line; `$1`, `${name}`, `$$` with `regex`), answering `{text, count, edits}` per text.
  Wakil's preview and its open tabs' buffers (3b-ii-b).
- `files_replace` — the write: every match in the files `files_search` covers, each file atomic and
  mode-kept; `skip` leaves the open tabs on disk (`skipped` lists those covered), `only` names one
  file. Answers each file's `original` and `mtime` for the undo, and `failures` whole. `max_files`
  (or 250 ms) ends a call early and `next` resumes it, so a Cancel lands between calls.
```

- [ ] **Step 4: Run them; they pass, with the old tests**

Run: `go test ./internal/wakilcore/ && go test ./cmd/wakil-files/`
Expected: PASS.

- [ ] **Step 5: Commit on the new layer**

```bash
gh stack add yehia-khalil/3b-ii-b-1-replace-go
git add internal/wakilcore/files.go internal/wakilcore/files_test.go cmd/wakil-files docs/architecture/go.md
git commit -m "wakil-files: files_replace_text and files_replace — search's pattern, every match, atomic per file, resumable (3b-ii-b PR 1)"
```

---

### Task 2: The replace model; `editor_replace`, `editor_replace_undo`, the Replace field and its preview (PR 2)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorReplace.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorSearch.swift`, `EditorPaneKind.swift`, `PaneStore+Editor.swift`, `EditorActions.swift`
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift` (`read_pane`'s description)
- Modify: `app/Tests/WakilKitTests/EditorTestSupport.swift` (FakeFiles answers `files_replace` and `files_replace_text`)
- Modify: `app/Tests/WakilKitTests/EditorReadPaneTests.swift` (the golden shape gains three keys),
  `AppWiringTests.swift`, `WindowModelPaletteTests.swift` (the pinned action lists)
- Test: `app/Tests/WakilKitTests/EditorReplaceTests.swift` (new), `EditorReplaceActionsTests.swift` (new)

**Interfaces:**
- Consumes: Task 1's two tools; `filesTool`, `EditorSearchState`, `editorReplacing`, `EditorAgentEdit`,
  `confine`, `editorPane`, `reply` (all existing).
- Produces (WakilKit, public unless noted):
  - `EditorReplaceEdit{start, end: Int; text: String}`
  - `EditorReplaceUndoRecord{path: String; count: Int; original: String; mtime: Int64}`
  - `EditorReplaceFailure{path, error: String}` with `static let changedSince = "changed since the replace — left as it is"`
    and `static let stopped = "the undo stopped before this file; it was left as it is"`
  - `EditorReplaceResult{replaced, files: Int; failures; undo; cancelled, undone: Bool; restored: Int}`, `var undoable: Bool`
  - `EditorReplaceState{text: String; shown, inFlight, undoing, cancelRequested: Bool; last: EditorReplaceResult?;
    preview: [String: [EditorReplaceEdit]]; previewSerial: Int}`, `static let closed`. `undoing` is true
    only while `editor_replace_undo` runs (with `inFlight`), so the view says "undoing" and its Cancel
    stops the undo (pre-flight F6).
  - `EditorPaneRef{scope: LayoutScope; paneId: String; paths: [String]}`; on `PaneStore`:
    `editorPanesInEveryScope() -> [EditorPaneRef]` (every editor pane the store holds, in the active
    scope and every other, with the file paths of its tabs) and `editorSnapshot(in:paneId:)`
    (pre-flight F2).
  - `EditorSearchState.replace: EditorReplaceState` (init parameter `replace: EditorReplaceState = .closed`, last)
  - `EditorReplaceSpan` (`.kept`, `.removed`, `.inserted`, each a `String`) and
    `editorReplacePreviewSpans(_ preview: String, edits: [EditorReplaceEdit]) -> [EditorReplaceSpan]`
  - `editorReplacePreviewTexts(_ results: [EditorSearchMatch]) -> [String]`
  - `editorReplaceChange(old: String, new: String) -> (range: EditorRange, text: String)?`
  - `editorPosition(_ text: String, utf16Offset: Int) -> EditorPosition`
  - `editorReplaceSummary(_ r: EditorReplaceResult) -> String`
  - `editorReplaceAvailable(_ s: EditorSearchState) -> Bool`
  - `EditorActionError.nothingToUndo`
  - internal: `editorReplaceBatchFiles = 50`, `EditorReplacedText`, `editorReplacedTexts(from:)`,
    `EditorReplaceBatch`, `editorReplaceBatch(from:)`, `EditorReplaceRun`, `editorReplaceJSON(_:)`,
    `editorReplaceFailuresJSON(_:)`.
- Produces (actions):

| Action | Kind | Params | Does |
|---|---|---|---|
| `editor_replace` | mutate, price (allow, allow) | `pane?`, `replacement`, `file?`, `cancel?` | the replace (rulings 1, 2, 5, 9), answering `replaced`, `files`, `failures` with the pane's state; `cancel` also stops an undo in flight |
| `editor_replace_undo` | mutate, price (allow, allow) | `pane?` | the undo, stopped between files by `editor_replace {cancel}` (the rest listed as stopped); refused with `nothingToUndo` |
| `editor_search` (existing) | control | gains `replace` (string or null) | the Replace field whenever `replace` is present (ruling 3), with or without `query`; the preview after any results |

**Rulings that apply here:** 1, 2, 3, 4, 5, 9, 10, 11.

- [ ] **Step 1: Teach FakeFiles the two tools**

In `EditorTestSupport.swift`, beside the search fakes. The fake replaces **literally and case-sensitively**
(it is not Go); it walks its disk in sorted path order, writes at most `replaceBatch` files per call
and answers `next` as the last path it handled:

```swift
    /// `files_replace`: a write that fails for a path, with its text.
    var replaceFailures: [String: String] = [:]
    /// Both replace tools answer this as `isError`, as Go answers an invalid regex.
    var replaceError: String?
    /// Files one `files_replace` call writes before it answers `next` (Go's `max_files` and 250 ms).
    var replaceBatch = 50
    /// Parks `files_replace` AFTER it has written, until `releaseReplace()`, latched.
    var slowReplace = false
    private var replaceReleased = false
    private var parkedReplaces: [CheckedContinuation<Void, Never>] = []
    /// Parks `files_replace_text` before it answers, until `releaseReplaceText()`, latched.
    var slowReplaceText = false
    private var replaceTextReleased = false
    private var parkedReplaceTexts: [CheckedContinuation<Void, Never>] = []
    func setReplaceFailure(_ path: String, _ text: String) { replaceFailures[path] = text }
    func setReplaceError(_ e: String?) { replaceError = e }
    func setReplaceBatch(_ n: Int) { replaceBatch = n }
    func setSlowReplace(_ on: Bool) { slowReplace = on; replaceReleased = false }
    func releaseReplace() { replaceReleased = true; parkedReplaces.forEach { $0.resume() }; parkedReplaces = [] }
    private func parkReplace(_ c: CheckedContinuation<Void, Never>) {
        if replaceReleased { c.resume() } else { parkedReplaces.append(c) }
    }
    func setSlowReplaceText(_ on: Bool) { slowReplaceText = on; replaceTextReleased = false }
    func releaseReplaceText() { replaceTextReleased = true; parkedReplaceTexts.forEach { $0.resume() }; parkedReplaceTexts = [] }
    private func parkReplaceText(_ c: CheckedContinuation<Void, Never>) {
        if replaceTextReleased { c.resume() } else { parkedReplaceTexts.append(c) }
    }
    private func strings(_ arguments: JSONValue, _ key: String) -> [String] {
        guard case .object(let o) = arguments, case .array(let items)? = o[key] else { return [] }
        return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }
```

In `callTool`, before `return result`, and the text park **before** `perform` (so the call answers what
the buffer held when it was sent, and the test can type meanwhile):

```swift
        if name == "files_replace", slowReplace { await withCheckedContinuation { c in Task { self.parkReplace(c) } } }
```

```swift
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if name == "files_replace_text", slowReplaceText {
            calls.append("files_replace_text parked")
            await withCheckedContinuation { c in Task { self.parkReplaceText(c) } }
        }
        let result = try await perform(name: name, arguments: arguments)
        // … the existing parks …
```

In `perform`, two cases:

```swift
        case "files_replace_text":
            if let replaceError { return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(replaceError)])])]) }
            let query = optionalString(arguments, "query") ?? "", with = optionalString(arguments, "replacement") ?? ""
            return ok(["results": .array(strings(arguments, "texts").map { t in
                let ns = t as NSString
                var edits: [JSONValue] = []
                var at = 0
                while !query.isEmpty, at < ns.length {
                    let r = ns.range(of: query, options: [], range: NSRange(location: at, length: ns.length - at))
                    if r.location == NSNotFound { break }
                    edits.append(.object(["start": .integer(Int64(r.location)), "end": .integer(Int64(r.location + r.length)), "text": .string(with)]))
                    at = r.location + r.length
                }
                let text = query.isEmpty ? t : t.replacingOccurrences(of: query, with: with)
                return .object(["text": .string(text), "count": .integer(Int64(edits.count)), "edits": .array(edits)])
            })])
        case "files_replace":
            if let replaceError { return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(replaceError)])])]) }
            let query = optionalString(arguments, "query") ?? "", with = optionalString(arguments, "replacement") ?? ""
            let only = optionalString(arguments, "only"), after = optionalString(arguments, "after") ?? ""
            let skip = strings(arguments, "skip")
            var files: [JSONValue] = [], failures: [JSONValue] = [], skipped: [JSONValue] = []
            var written = 0, last = "", stopped = false
            for path in disk.keys.sorted() where path > after && (only == nil || path == only) {
                if written >= replaceBatch { stopped = true; break }
                last = path
                if skip.contains(path) { skipped.append(.string(path)); continue }
                let old = disk[path]!.text
                let count = query.isEmpty ? 0 : old.components(separatedBy: query).count - 1
                guard count > 0 else { continue }
                if let f = replaceFailures[path] { failures.append(.object(["path": .string(path), "error": .string(f)])); continue }
                put(path, old.replacingOccurrences(of: query, with: with))
                files.append(.object(["path": .string(path), "count": .integer(Int64(count)), "original": .string(old),
                                      "mtime": .integer(disk[path]!.mtime)]))
                written += 1
            }
            return ok(["files": .array(files), "failures": .array(failures), "skipped": .array(skipped),
                       "truncated_files": .bool(false), "cancelled": .bool(false), "next": .string(stopped ? last : "")])
```

`perform` records each call as `"\(name) \(path)"`, and neither tool has `path` or `root`, so they read
`"files_replace "` and `"files_replace_text "`.

- [ ] **Step 2: Write the failing tests**

`EditorReplaceTests.swift` (the pure helpers):

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func aReplaceChangeIsTheSmallestSpanThatDiffers() throws {
    let c = try #require(editorReplaceChange(old: "let foo = 1\nfoo()\n", new: "let bar = 1\nfoo()\n"))
    #expect(c.range == EditorRange(start: EditorPosition(line: 1, column: 5), end: EditorPosition(line: 1, column: 8)))
    #expect(c.text == "bar")
    #expect(editorReplaceChange(old: "same", new: "same") == nil)
    let two = try #require(editorReplaceChange(old: "foo\nx\nfoo", new: "bar\nx\nbar"))
    #expect(two.range == EditorRange(start: EditorPosition(line: 1, column: 1), end: EditorPosition(line: 3, column: 4)))
    #expect(two.text == "bar\nx\nbar")
}

@Test func aReplaceChangeNeverSplitsASurrogatePair() throws {
    // 😀 and 😃 share their lead surrogate: the span must start at the pair, not inside it.
    let c = try #require(editorReplaceChange(old: "a😀b", new: "a😃b"))
    #expect(c.range == EditorRange(start: EditorPosition(line: 1, column: 2), end: EditorPosition(line: 1, column: 4)))
    #expect(c.text == "😃")
}

@Test func previewSpansStrikeTheMatchAndInsertTheReplacement() {
    let spans = editorReplacePreviewSpans("let foo = foo", edits: [EditorReplaceEdit(start: 4, end: 7, text: "bar"),
                                                                    EditorReplaceEdit(start: 10, end: 13, text: "")])
    #expect(spans == [.kept("let "), .removed("foo"), .inserted("bar"), .kept(" = "), .removed("foo")])
    #expect(editorReplacePreviewSpans("abc", edits: [EditorReplaceEdit(start: 2, end: 9, text: "x")]) == [.kept("abc")])
}

@Test func previewTextsAreEachShownLineOnce() {
    let m = { (p: String, l: Int, line: String) in EditorSearchMatch(root: "/p/api", path: p, line: l, column: 1, preview: line) }
    #expect(editorReplacePreviewTexts([m("a.go", 1, "foo()"), m("a.go", 1, "foo()"), m("b.go", 3, "x foo")]) == ["foo()", "x foo"])
}

@Test func theResultLineSaysWhatHappened() {
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 37, files: 12)) == "Replaced 37 in 12 files")
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 1, files: 1)) == "Replaced 1 in 1 file")
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 3, files: 2, cancelled: true)) == "Replace cancelled · replaced 3 in 2 files")
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 3, files: 2, undone: true, restored: 1)) == "Undid the replace in 1 file")
}

@Test func replaceIsAvailableOnlyOverResultsWithNoErrorAndNothingInFlight() {
    var s = EditorSearchState.empty
    s.query = "foo"
    s.results = [EditorSearchMatch(root: "/p/api", path: "a.go", line: 1, column: 1, preview: "foo")]
    #expect(editorReplaceAvailable(s))
    var e = s; e.error = "error parsing regexp"; #expect(!editorReplaceAvailable(e))
    var f = s; f.replace.inFlight = true; #expect(!editorReplaceAvailable(f))
    var g = s; g.results = []; #expect(!editorReplaceAvailable(g))
    var h = s; h.query = ""; #expect(!editorReplaceAvailable(h))
}

@Test func anUndoableResultHasRecordsAndIsNotUndone() {
    let r = EditorReplaceUndoRecord(path: "/p/api/a.go", count: 1, original: "foo", mtime: 7)
    #expect(EditorReplaceResult(replaced: 1, files: 1, undo: [r]).undoable)
    #expect(!EditorReplaceResult(replaced: 1, files: 1, undo: [r], undone: true).undoable)
    #expect(!EditorReplaceResult(replaced: 1, files: 1).undoable)          // a buffer-only replace
}
```

`EditorReplaceActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// a.go and b.go under /p/api and c.ts under /p/web, each holding "foo"; the Search view on "foo".
private func replaceFixture() async throws -> EditorFixture {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "let foo = 1\n")
    await f.files.put("/p/api/b.go", "foo()\nfoo()\n")
    await f.files.put("/p/web/c.ts", "const foo = 3\n")
    await f.files.setSearch([("/p/api", "a.go", 1, 5, "let foo = 1"), ("/p/api", "b.go", 1, 1, "foo()"),
                             ("/p/api", "b.go", 2, 1, "foo()"), ("/p/web", "c.ts", 1, 7, "const foo = 3")])
    try await f.dispatch("editor_search", ["query": .string("foo")])
    return f
}

@Test func replaceWritesTheClosedFilesAndRecordsTheUndo() async throws {
    let f = try await replaceFixture()
    let reply = try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
    let s = await f.snapshot().search.replace
    let last = try #require(s.last)
    #expect(last.replaced == 4 && last.files == 3 && last.failures.isEmpty && last.undoable && !s.inFlight)
    #expect(last.undo.map(\.path) == ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"])
    #expect(last.undo[1].original == "foo()\nfoo()\n")
    #expect(s.shown && s.text == "bar")                         // the field shows what was replaced with
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["replaced"] == .number(4) && o["files"] == .number(3))
}

@Test func aDirtyOpenTabGetsABufferEditAndItsFileIsUntouched() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "let foo = 1 // mine\n", basis: 0)
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")     // its disk is never written
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "let bar = 1 // mine\n" && t.dirty)
    #expect(t.lastAgentEdit?.range == EditorRange(start: EditorPosition(line: 1, column: 5), end: EditorPosition(line: 1, column: 8)))
    #expect(t.lastAgentEdit?.text == "bar")
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(!last.undo.contains { $0.path == "/p/api/a.go" })              // buffer edits are ⌘Z's
    #expect(last.files == 3 && last.replaced == 4)
}

// Pre-flight F2: the store keeps the editor panes of the project's other conversations in memory
// (`everyScope`), and a file open there is "open in a pane of the window" too (spec, Open tabs).
@Test func aDirtyTabInAScopeNotOnScreenIsEditedInItsBufferAndItsFileIsNeverWritten() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let subject = await f.snapshot().tabs[0].subject
    await f.panes.editorBufferDidChange(paneId: f.pane, subject: subject, text: "let foo = 1 // mine\n", basis: 0)
    let home = await f.panes.activeScope
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    try await f.dispatch("editor_search", ["query": .string("foo")])          // the other conversation's Search view
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")        // the hidden tab's file is not written
    let hidden = await f.panes.editorSnapshot(in: home, paneId: f.pane).tabs[0]
    #expect(hidden.text == "let bar = 1 // mine\n" && hidden.dirty)
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(!last.undo.contains { $0.path == "/p/api/a.go" } && last.files == 3 && last.replaced == 4)
}

@Test func theStoreListsEveryEditorPaneOfEveryScopeWithItsPaths() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let home = await f.panes.activeScope
    let other = LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2")
    await f.panes.switchScope(to: other)
    try await f.dispatch("editor_open", ["path": .string("/p/web/c.ts")])
    var seen: [String: [String]] = [:]
    for ref in await f.panes.editorPanesInEveryScope() { seen["\(ref.scope.lineageRoot ?? "-")"] = ref.paths }
    #expect(seen == ["-": ["/p/api/a.go"], "conv-2": ["/p/web/c.ts"]])
}

// Pre-flight F7: a file open in two panes is one file with one count.
@Test func aFileOpenInTwoPanesIsCountedOnce() async throws {
    let f = try await replaceFixture()
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["pane": .string(other), "path": .string("/p/api/a.go")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.replaced == 4 && last.files == 3)              // a.go 1 once, not twice; b.go 2; c.ts 1
    #expect(await f.panes.editorSnapshot(paneId: other).tabs[0].text == "let bar = 1\n")
}

@Test func aTabOpenInAnotherEditorPaneIsEditedThere() async throws {
    let f = try await replaceFixture()
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_open", ["pane": .string(other), "path": .string("/p/web/c.ts")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/web/c.ts") == "const foo = 3\n")
    #expect(await f.panes.editorSnapshot(paneId: other).tabs[0].text == "const bar = 3\n")
}

// Review Focus 1.
@Test func aBufferTypedInDuringTheReplaceIsReplacedAgainNotOverwritten() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.files.setSlowReplaceText(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace_text parked")) { await Task.yield() }
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "let foo = 1\nfoo typed\n", basis: 0)
    await f.files.releaseReplaceText()
    _ = try await run.value
    #expect(await f.snapshot().tabs[0].text == "let bar = 1\nbar typed\n")
}

@Test func aCancelStopsBetweenBatchesAndKeepsWhatWasWritten() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceBatch(1)
    await f.files.setSlowReplace(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    #expect(await f.snapshot().search.replace.inFlight)
    try await f.dispatch("editor_replace", ["cancel": .bool(true)])
    await f.files.releaseReplace()
    _ = try await run.value
    #expect(await f.files.text(of: "/p/api/a.go") == "let bar = 1\n")       // the batch in flight landed
    #expect(await f.files.text(of: "/p/api/b.go") == "foo()\nfoo()\n")
    let s = await f.snapshot().search.replace
    #expect(!s.inFlight && s.last?.cancelled == true && s.last?.undo.map(\.path) == ["/p/api/a.go"])
}

@Test func undoShowsItsOwnStateAndItsCancelStopsItBetweenFiles() async throws {   // pre-flight F6
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    await f.files.setSlowRead(true)                                    // parks the undo's first files_read
    let run = Task { try await f.dispatch("editor_replace_undo") }
    while !(await f.files.calls.contains { $0.hasPrefix("files_read") }) { await Task.yield() }
    let during = await f.snapshot().search.replace
    #expect(during.inFlight && during.undoing)
    try await f.dispatch("editor_replace", ["cancel": .bool(true)])    // the same Cancel the view draws
    await f.files.releaseRead()
    _ = try await run.value
    let s = await f.snapshot().search.replace
    #expect(!s.inFlight && !s.undoing && !s.cancelRequested)
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")           // the file in hand was restored
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")          // later files were left, and listed
    let last = try #require(s.last)
    #expect(last.undone && last.restored == 1)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: EditorReplaceFailure.stopped),
                              EditorReplaceFailure(path: "/p/web/c.ts", error: EditorReplaceFailure.stopped)])
}

@Test func aSecondReplaceWhileOneRunsStartsNothing() async throws {
    let f = try await replaceFixture()
    await f.files.setSlowReplace(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    try await f.dispatch("editor_replace", ["replacement": .string("baz")])
    await f.files.releaseReplace()
    _ = try await run.value
    #expect(await f.files.calls.filter { $0 == "files_replace " }.count == 1)
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
}

@Test func aFailedWriteIsListedWholeAndTheRestGoThrough() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceFailure("/p/api/b.go", "/p/api/b.go is not writable: permission denied")
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: "/p/api/b.go is not writable: permission denied")])
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
}

@Test func anInvalidPatternIsGosErrorWholeAndRecordsNothing() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceError("error parsing regexp: missing closing ): `foo(`")
    do {
        try await f.dispatch("editor_replace", ["replacement": .string("bar")])
        Issue.record("expected Go's error")
    } catch { #expect(String(describing: error).contains("missing closing )")) }
    let s = await f.snapshot().search.replace
    #expect(s.last == nil && !s.inFlight)
}

@Test func fileLimitsTheReplaceToOneFileInsideTheRoots() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar"), "file": .string("/p/api/b.go")])
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == "const foo = 3\n")
    do {
        try await f.dispatch("editor_replace", ["replacement": .string("x"), "file": .string("/etc/hosts")])
        Issue.record("expected the refusal")
    } catch { #expect(String(describing: error).contains("Invariant 6")) }
}

@Test func aReplaceWithNoQueryChangesNothing() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "foo")
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "foo")
    #expect(await f.snapshot().search.replace.last == nil)
}

@Test func theSearchRunsAgainAfterAReplace() async throws {
    let f = try await replaceFixture()
    await f.files.setSearch([("/p/api", "a.go", 1, 5, "let foo = 1")])     // what is left
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let calls = await f.files.calls
    let replaced = try #require(calls.lastIndex(of: "files_replace "))
    #expect(calls[replaced...].contains { $0.hasPrefix("files_search") })
    #expect(await f.snapshot().search.results.map(\.path) == ["a.go"])
}

@Test func undoRestoresUnchangedFilesAndLeavesThoseChangedOrDeletedSince() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    await f.files.put("/p/api/b.go", "bar()\nmine\n")          // changed since: a new mtime
    await f.files.remove("/p/web/c.ts")                        // deleted since
    let reply = try await f.dispatch("editor_replace_undo")
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nmine\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == nil)
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.undone && !last.undoable && last.restored == 1)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: EditorReplaceFailure.changedSince),
                              EditorReplaceFailure(path: "/p/web/c.ts", error: EditorReplaceFailure.changedSince)])
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["restored"] == .number(1))
}

@Test func undoWithNothingToUndoIsRefused() async throws {
    let f = try await replaceFixture()
    await #expect(throws: EditorActionError.nothingToUndo) { try await f.dispatch("editor_replace_undo") }
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    try await f.dispatch("editor_replace_undo")
    await #expect(throws: EditorActionError.nothingToUndo) { try await f.dispatch("editor_replace_undo") }
}

@Test func theReplaceFieldPreviewsEveryShownLineInOneCallAndKeepsItsText() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_search", ["replace": .string("bar")])
    let s = await f.snapshot().search
    #expect(s.replace.shown && s.replace.text == "bar" && s.query == "foo")
    #expect(s.replace.preview["foo()"] == [EditorReplaceEdit(start: 0, end: 3, text: "bar")])
    #expect(s.replace.preview.count == 3)
    #expect(await f.files.calls.filter { $0.hasPrefix("files_replace_text") }.count == 1)
    try await f.dispatch("editor_search", ["replace": .null])
    let closed = await f.snapshot().search.replace
    #expect(!closed.shown && closed.text == "bar" && closed.preview.isEmpty)   // Rule 2
}

// Pre-flight F1: `replace` with `query` sets the field and searches; it is not dropped.
@Test func searchWithBothAQueryAndAReplaceSetsTheFieldAndSearches() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/b.go", "foo()\n")
    await f.files.setSearch([("/p/api", "b.go", 1, 1, "foo()")])
    try await f.dispatch("editor_search", ["query": .string("foo"), "replace": .string("bar")])
    let s = await f.snapshot().search
    #expect(s.query == "foo" && s.results.map(\.path) == ["b.go"])
    #expect(s.replace.shown && s.replace.text == "bar")
    #expect(s.replace.preview["foo()"] == [EditorReplaceEdit(start: 0, end: 3, text: "bar")])
    try await f.dispatch("editor_search", ["query": .string("foo"), "replace": .null])
    #expect(await f.snapshot().search.replace.shown == false)
}

@Test func anEmptyReplaceFieldPreviewsDeletingTheMatches() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_search", ["replace": .string("")])
    #expect(await f.snapshot().search.replace.preview["foo()"] == [EditorReplaceEdit(start: 0, end: 3, text: "")])
}

@Test func newResultsArePreviewedAgain() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_search", ["replace": .string("bar")])
    await f.files.setSearch([("/p/api", "d.go", 1, 1, "foo baz")])
    try await f.dispatch("editor_search", ["query": .string("foo")])
    #expect(await f.snapshot().search.replace.preview.keys.sorted() == ["foo baz"])
}

@Test func readPaneReportsTheFieldTheFlightAndTheLastReplace() async throws {
    let f = try await replaceFixture()
    func search() async -> [String: JSONValue] {
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .object(let s)? = o["search"] else { return [:] }
        return s
    }
    let before = await search()
    #expect(before["replace"] == .null && before["last_replace"] == .null)
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let s = await search()
    #expect(s["replace"] == .string("bar") && s["replace_in_flight"] == .bool(false))
    #expect(s["last_replace"] == .object([
        "replaced": .number(4), "files": .number(3), "failures": .array([]), "undoable": .bool(true),
        "undone": .bool(false), "restored": .number(0), "cancelled": .bool(false)]))
}

@Test func replaceAndUndoDeclareAllowEverywhere() async throws {
    let f = try await editorFixture()
    for name in ["editor_replace", "editor_replace_undo"] {
        let a = try #require(await f.registry.all().first { $0.name == name })
        #expect(a.kind == .mutate && a.audience == .agentReachable)
    }
    await f.files.put("/p/api/a.go", "foo")
    await f.files.setSearch([("/p/api", "a.go", 1, 1, "foo")])
    try await f.dispatch("editor_search", ["query": .string("foo")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")], origin: .agent, environment: "production")
    #expect(await f.files.text(of: "/p/api/a.go") == "bar")
}
```

`EditorReadPaneTests.swift`'s golden shape: its `"search"` object gains
`"replace": .null, "replace_in_flight": .bool(false), "last_replace": .null`.

The pinned lists gain the two names:
- `AppWiringTests.swift`: `"editor_replace", "editor_replace_range", "editor_replace_undo"` in sorted
  position.
- `WindowModelPaletteTests.swift`'s `registeredBeforeThePalette`: `"editor_replace", "editor_replace_undo"`.
  **Not** `agentToolsBeforeThePalette`: a `.mutate` action is not in the agent's `--allowedTools`
  (`editor_save` is absent there for the same reason); its price answers the prompt.

- [ ] **Step 3: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorReplace|readPaneForAnEditorIsTheGoldenShape'`
Expected: compile failure — `EditorReplaceEdit`, `editorReplaceChange`, `search.replace` and
`EditorActionError.nothingToUndo` are undefined.

- [ ] **Step 4: Implement the model**

`EditorReplace.swift`:

```swift
import Foundation

/// How many files one `files_replace` call may write before it answers `next` (Go also ends a call
/// after 250 ms). Cancel lands between calls (3b-ii-b ruling 1).
let editorReplaceBatchFiles = 50

/// One replacement in a text: the UTF-16 span [start, end) it replaces, and what goes there.
public struct EditorReplaceEdit: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var text: String
    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One file a replace wrote: what its undo puts back, and the mtime it must still have.
public struct EditorReplaceUndoRecord: Sendable, Equatable {
    public var path: String
    public var count: Int
    public var original: String
    public var mtime: Int64
    public init(path: String, count: Int, original: String, mtime: Int64) {
        self.path = path
        self.count = count
        self.original = original
        self.mtime = mtime
    }
}

/// A file a replace or its undo could not change, with why, whole (Rule 8).
public struct EditorReplaceFailure: Sendable, Equatable {
    public var path: String
    public var error: String
    public static let changedSince = "changed since the replace — left as it is"
    public static let stopped = "the undo stopped before this file; it was left as it is"
    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

/// The pane's latest replace: what the result line says, and its one undo (spec: one, in memory).
public struct EditorReplaceResult: Sendable, Equatable {
    public var replaced: Int
    /// Files changed: written, or edited in an open tab's buffer.
    public var files: Int
    public var failures: [EditorReplaceFailure]
    /// The files written, never the buffers (those are ⌘Z's in their tab).
    public var undo: [EditorReplaceUndoRecord]
    public var cancelled: Bool
    public var undone: Bool
    public var restored: Int
    public var undoable: Bool { !undone && !undo.isEmpty }
    public init(replaced: Int, files: Int, failures: [EditorReplaceFailure] = [], undo: [EditorReplaceUndoRecord] = [],
                cancelled: Bool = false, undone: Bool = false, restored: Int = 0) {
        self.replaced = replaced
        self.files = files
        self.failures = failures
        self.undo = undo
        self.cancelled = cancelled
        self.undone = undone
        self.restored = restored
    }
}

/// The Search view's Replace (3b-ii-b): the field, its toggle, the run in flight, the latest result
/// and the preview of each shown line.
public struct EditorReplaceState: Sendable, Equatable {
    /// The field's text, kept while the toggle is closed (Rule 2).
    public var text: String
    public var shown: Bool
    public var inFlight: Bool
    /// The run in flight is an undo (`inFlight` is true too): the view says "undoing" (pre-flight F6).
    public var undoing: Bool
    /// Cancel was pressed: the run stops before its next `files_replace` call, or the undo before its
    /// next file.
    public var cancelRequested: Bool
    public var last: EditorReplaceResult?
    /// Each shown result line's replacements, keyed by the line's preview text.
    public var preview: [String: [EditorReplaceEdit]]
    /// Bumps per preview asked for; an older answer is dropped.
    public var previewSerial: Int
    public static let closed = EditorReplaceState(text: "", shown: false, inFlight: false, undoing: false,
                                                  cancelRequested: false, last: nil, preview: [:], previewSerial: 0)
    public init(text: String, shown: Bool, inFlight: Bool, undoing: Bool, cancelRequested: Bool, last: EditorReplaceResult?,
                preview: [String: [EditorReplaceEdit]], previewSerial: Int) {
        self.text = text
        self.shown = shown
        self.inFlight = inFlight
        self.undoing = undoing
        self.cancelRequested = cancelRequested
        self.last = last
        self.preview = preview
        self.previewSerial = previewSerial
    }
}

/// A result line's pieces: kept text, the match struck through, and its replacement in violet.
public enum EditorReplaceSpan: Sendable, Equatable { case kept(String), removed(String), inserted(String) }

public func editorReplacePreviewSpans(_ preview: String, edits: [EditorReplaceEdit]) -> [EditorReplaceSpan] {
    let u = Array(preview.utf16)
    func piece(_ r: Range<Int>) -> String { String(decoding: u[r], as: UTF16.self) }
    var out: [EditorReplaceSpan] = []
    var at = 0
    for e in edits where e.start >= at && e.start <= e.end && e.end <= u.count {
        if e.start > at { out.append(.kept(piece(at..<e.start))) }
        if e.end > e.start { out.append(.removed(piece(e.start..<e.end))) }
        if !e.text.isEmpty { out.append(.inserted(e.text)) }
        at = e.end
    }
    if at < u.count { out.append(.kept(piece(at..<u.count))) }
    return out
}

/// The preview's one call: each shown line once, in order.
public func editorReplacePreviewTexts(_ results: [EditorSearchMatch]) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for m in results where seen.insert(m.preview).inserted { out.append(m.preview) }
    return out
}

/// The 1-based position (UTF-16 column) of a UTF-16 offset.
public func editorPosition(_ text: String, utf16Offset offset: Int) -> EditorPosition {
    var line = 1, column = 1, i = 0
    for u in text.utf16 {
        if i == offset { break }
        if u == 10 { line += 1; column = 1 } else { column += 1 }
        i += 1
    }
    return EditorPosition(line: line, column: column)
}

/// The one agent edit that turns `old` into `new`: the smallest span that differs, never inside a
/// surrogate pair. nil when they are the same.
public func editorReplaceChange(old: String, new: String) -> (range: EditorRange, text: String)? {
    guard old != new else { return nil }
    let a = Array(old.utf16), b = Array(new.utf16)
    var p = 0
    while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
    if p > 0, (p < a.count && UTF16.isTrailSurrogate(a[p])) || (p < b.count && UTF16.isTrailSurrogate(b[p])) { p -= 1 }
    var s = 0
    while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    if s > 0, UTF16.isTrailSurrogate(a[a.count - s]) { s -= 1 }
    let text = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
    return (EditorRange(start: editorPosition(old, utf16Offset: p), end: editorPosition(old, utf16Offset: a.count - s)), text)
}

public func editorReplaceSummary(_ r: EditorReplaceResult) -> String {
    func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
    if r.undone { return "Undid the replace in \(files(r.restored))" }
    let what = "\(r.replaced) in \(files(r.files))"
    return r.cancelled ? "Replace cancelled · replaced \(what)" : "Replaced \(what)"
}

/// Replace All and Replace in this file are pressable: a query with results, no error, none running.
public func editorReplaceAvailable(_ s: EditorSearchState) -> Bool {
    !s.query.isEmpty && s.error == nil && !s.replace.inFlight && !s.results.isEmpty
}

// MARK: - Replies (internal)

struct EditorReplacedText: Sendable, Equatable {
    var text: String
    var count: Int
    var edits: [EditorReplaceEdit]
}

private func editorStrings(_ v: JSONValue?) -> [String] {
    guard case .array(let items)? = v else { return [] }
    return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
}

private func editorEdits(_ v: JSONValue?) -> [EditorReplaceEdit] {
    guard case .array(let items)? = v else { return [] }
    return items.compactMap { item in
        guard case .object(let e) = item, let start = e["start"]?.intValue, let end = e["end"]?.intValue,
              case .string(let text)? = e["text"] else { return nil }
        return EditorReplaceEdit(start: start, end: end, text: text)
    }
}

/// `files_replace_text`'s `results`, in order.
func editorReplacedTexts(from o: [String: JSONValue]) -> [EditorReplacedText] {
    guard case .array(let items)? = o["results"] else { return [] }
    return items.compactMap { item in
        guard case .object(let r) = item, case .string(let text)? = r["text"] else { return nil }
        return EditorReplacedText(text: text, count: r["count"]?.intValue ?? 0, edits: editorEdits(r["edits"]))
    }
}

/// One `files_replace` reply.
struct EditorReplaceBatch: Sendable, Equatable {
    var written: [EditorReplaceUndoRecord]
    var failures: [EditorReplaceFailure]
    var skipped: [String]
    var next: String
}

func editorReplaceBatch(from o: [String: JSONValue]) -> EditorReplaceBatch {
    var written: [EditorReplaceUndoRecord] = []
    if case .array(let items)? = o["files"] {
        for item in items {
            guard case .object(let f) = item, case .string(let path)? = f["path"],
                  case .string(let original)? = f["original"] else { continue }
            written.append(EditorReplaceUndoRecord(path: path, count: f["count"]?.intValue ?? 0, original: original,
                                                   mtime: Int64(f["mtime"]?.intValue ?? 0)))
        }
    }
    var failures: [EditorReplaceFailure] = []
    if case .array(let items)? = o["failures"] {
        for item in items {
            guard case .object(let f) = item, case .string(let path)? = f["path"], case .string(let error)? = f["error"] else { continue }
            failures.append(EditorReplaceFailure(path: path, error: error))
        }
    }
    let next: String = { if case .string(let n)? = o["next"] { n } else { "" } }()
    return EditorReplaceBatch(written: written, failures: failures, skipped: editorStrings(o["skipped"]), next: next)
}

/// What a replace run has done so far, batch by batch, then its buffers.
struct EditorReplaceRun: Sendable {
    var undo: [EditorReplaceUndoRecord] = []
    var failures: [EditorReplaceFailure] = []
    var skipped: Set<String> = []
    var replaced = 0
    var paths: Set<String> = []
    var cancelled = false

    mutating func add(_ b: EditorReplaceBatch) {
        undo += b.written
        failures += b.failures
        skipped.formUnion(b.skipped)
        for r in b.written { replaced += r.count; paths.insert(r.path) }
    }

    mutating func addBuffers(count: Int, paths edited: Set<String>) {
        replaced += count
        paths.formUnion(edited)
    }

    var result: EditorReplaceResult {
        EditorReplaceResult(replaced: replaced, files: paths.count, failures: failures, undo: undo, cancelled: cancelled)
    }
}

func editorReplaceFailuresJSON(_ failures: [EditorReplaceFailure]) -> JSONValue {
    .array(failures.map { .object(["path": .string($0.path), "error": .string($0.error)]) })
}

/// `read_pane`'s `last_replace`.
func editorReplaceJSON(_ r: EditorReplaceResult) -> JSONValue {
    .object(["replaced": .number(Double(r.replaced)), "files": .number(Double(r.files)),
             "failures": editorReplaceFailuresJSON(r.failures), "undoable": .bool(r.undoable),
             "undone": .bool(r.undone), "restored": .number(Double(r.restored)), "cancelled": .bool(r.cancelled)])
}
```

`EditorSearch.swift`: `EditorSearchState` gains, after `results`,

```swift
    /// The Replace field, its preview, the run in flight and the latest replace (3b-ii-b).
    public var replace: EditorReplaceState
```

and its `init` gains a last parameter `replace: EditorReplaceState = .closed`, stored.

`EditorPaneKind.readPane`, inside the `"search"` object:

```swift
            "replace": q.replace.shown ? .string(q.replace.text) : .null,
            "replace_in_flight": .bool(q.replace.inFlight),
            "last_replace": q.replace.last.map(editorReplaceJSON) ?? .null,
```

`PaneStore+Editor.swift`, `updateEditor`: the window must redraw when a replace starts and ends while
its dispatch is still running (the tick and Cancel, Rule 5), as for search:

```swift
        let before = (column: s.column, inFlight: s.search.inFlight, replacing: s.search.replace.inFlight,
                      undoing: s.search.replace.undoing)
        let result = change(&s)
        if holdsContents(paneId: paneId) || create {
            setContents(EditorPaneKind.self, paneId, s)
            if s.column != before.column || s.search.inFlight != before.inFlight
                || s.search.replace.inFlight != before.replacing
                || s.search.replace.undoing != before.undoing { publishEditorChange(paneId) }
        }
```

Beside `editorDirtyTabsInHiddenScopes`, the replace needs every editor pane the store holds, whatever
scope it is in (pre-flight F2: a project or conversation switch keeps a scope's panes and their tabs in
memory, `everyScope`), and a read in a scope that need not be the active one:

```swift
    /// Every editor pane the store holds, in the active scope and in every other, with the file paths of
    /// its tabs: `editor_replace` skips all of those paths on disk and edits their buffers instead.
    public func editorPanesInEveryScope() -> [EditorPaneRef] {
        var out: [EditorPaneRef] = []
        for entry in everyScope(EditorPaneKind.self) {
            var paths: [String] = []
            for t in entry.contents.tabs { if let path = t.path { paths.append(path) } }
            out.append(EditorPaneRef(scope: entry.scope, paneId: entry.paneId, paths: paths))
        }
        return out
    }

    /// `editorSnapshot` in `scope`, which need not be the active one.
    public func editorSnapshot(in scope: LayoutScope, paneId: String) -> EditorSnapshot {
        inScope(scope) { editorSnapshot(paneId: paneId) }
    }
```

```swift
/// An editor pane in some scope (`PaneStore.editorPanesInEveryScope`).
public struct EditorPaneRef: Sendable {
    public let scope: LayoutScope
    public let paneId: String
    public let paths: [String]
}
```

`EditorActionError` gains:

```swift
    /// `editor_replace_undo` with no replace to undo (the one refusal Rule 7 allows: nothing to override).
    case nothingToUndo
```

```swift
        case .nothingToUndo:
            "editor_replace_undo: this pane has no replace to undo; only its latest replace can be undone, "
                + "once, while the window is open"
```

`MCPServer.swift`, `read_pane`'s description: after *"…and results, each match's root, path, line,
column and preview"* add: *"replace is the Replace field's text, or null while it is closed;
replace_in_flight while a replace runs; last_replace is the latest replace — replaced, files,
failures (each path and error), undoable, undone, restored and cancelled — or null."*

- [ ] **Step 5: Implement the actions**

In `EditorActions.swift`:

`filesTool` gains a timeout, defaulting to today's:

```swift
private func filesTool(_ files: any ToolCaller, _ name: String, _ args: [String: JSONValue],
                       timeout: TimeInterval = MCPClient.readReplyTimeout) async throws -> FilesOutcome {
    let result: JSONValue
    do {
        result = try await files.callTool(name: name, arguments: .object(args), timeout: timeout)
```

`editor_search`'s non-empty-query body moves into a local function the replace and its undo also
call, so the search after a replace is the same search (place it after `matches(from:)`, and
`refreshReplacePreview` before it):

```swift
    @Sendable func replaceArgs(_ s: EditorSearchState, _ replacement: String) -> [String: JSONValue] {
        ["query": .string(s.query), "case": .bool(s.caseSensitive), "word": .bool(s.wholeWord),
         "regex": .bool(s.regex), "replacement": .string(replacement)]
    }

    /// `files_replace_text` over `texts`, answered in order (3b-ii-b).
    @Sendable func replaceTexts(_ files: any ToolCaller, _ texts: [String], _ s: EditorSearchState,
                                _ replacement: String) async throws -> [EditorReplacedText] {
        var args = replaceArgs(s, replacement)
        args["texts"] = .array(texts.map { .string($0) })
        switch try await filesTool(files, "files_replace_text", args) {
        case .failed(let text): throw EditorFilesError(description: text)
        case .ok(let o): return editorReplacedTexts(from: o)
        }
    }

    /// The preview: every shown line in one `files_replace_text` call, drawn from its answer. Cleared
    /// when the toggle is closed, the search failed or found nothing. A newer preview wins.
    @Sendable func refreshReplacePreview(_ pane: String) async {
        let s = await panes.editorSnapshot(paneId: pane).search
        guard let files, s.replace.shown, s.error == nil, !s.results.isEmpty else {
            await panes.updateEditor(paneId: pane) { st in st.search.replace.preview = [:] }
            return
        }
        let serial = await panes.updateEditor(paneId: pane) { st -> Int in
            st.search.replace.previewSerial += 1
            return st.search.replace.previewSerial
        }
        let texts = editorReplacePreviewTexts(s.results)
        let answer = try? await replaceTexts(files, texts, s, s.replace.text)
        await panes.updateEditor(paneId: pane) { st in
            guard st.search.replace.previewSerial == serial else { return }
            var preview: [String: [EditorReplaceEdit]] = [:]
            if let answer { for (t, r) in zip(texts, answer) { preview[t] = r.edits } }
            st.search.replace.preview = preview
        }
    }

    /// The search `editor_search` runs for a non-empty query (3b-ii), shared with a replace's and an
    /// undo's re-run (3b-ii-b), then the preview over what it found.
    @Sendable func runSearch(_ pane: String, query: String, caseSensitive c: Bool, wholeWord w: Bool,
                             regex r: Bool) async throws {
        let files = try requireFiles("editor_search")
        let args: [String: JSONValue] = ["query": .string(query), "case": .bool(c), "word": .bool(w), "regex": .bool(r)]
        let serial = await panes.updateEditor(paneId: pane, create: true) { s -> Int in
            s.search.serial += 1
            s.search.query = query
            s.search.caseSensitive = c; s.search.wholeWord = w; s.search.regex = r
            s.search.inFlight = true
            s.search.cancelled = false
            s.search.error = nil
            s.search.changedSince = false
            return s.search.serial
        }
        await updateColumn(pane, onlyIfChanged: true) { c in c.shown = true; c.view = .search }
        let task = await runs.start(pane, serial: serial) { try await filesTool(files, "files_search", args) }
        // … the existing outcome / runs.finish / updateEditor block, unchanged …
        await refreshReplacePreview(pane)
        if case .failure(let e) = outcome, !(e is CancellationError) { throw e }
    }
```

The `editor_search` handler then reads, after its `cancel` branch:

```swift
            // 3b-ii-b ruling 3: the Replace field — its text opens the toggle; null closes it and keeps
            // the text (Rule 2). Applied whenever `replace` is present (pre-flight F1), before any search so
            // the preview uses it. With no query, nothing is searched; with one, `runSearch` below
            // refreshes the preview.
            if let o = jsonObject(params), let field = o["replace"] {
                await panes.updateEditor(paneId: pane, create: true) { s in
                    if case .string(let t) = field { s.search.replace.text = t; s.search.replace.shown = true }
                    else { s.search.replace.shown = false }
                }
                if o["query"] == nil {
                    await refreshReplacePreview(pane)
                    return await reply(pane)
                }
            }
```

…its empty-query branch also sets `s.search.replace.preview = [:]`, and its non-empty branch becomes:

```swift
            try await runSearch(pane, query: optionalString(params, "query") ?? "", caseSensitive: flag(params, "case"),
                                wholeWord: flag(params, "word"), regex: flag(params, "regex"))
            return await reply(pane)
```

Its schema gains `"replace": .object(["type": .array([.string("string"), .string("null")])])`, and its
description gains: *"replace (a string) opens the Search view's Replace field with that text, or null
closes it keeping the text; sent without query, it searches nothing, and with query it also searches. While the field is open each
result line's replacement is previewed."*

Then the two actions, after `files_search`:

```swift
    /// Each open tab `skipped` names, in every editor pane the store holds — the active scope's and
    /// the other conversations' (pre-flight F2) — the replacement applied to its buffer as one agent
    /// edit (3b-i's path, so ⌘Z takes it back whole). A tab typed in while its text was being replaced
    /// is replaced again from what it holds now, up to three times — the operator's typing is never
    /// written over (Review Focus 1). A file open in two panes counts once, by its path (pre-flight
    /// F7). Answers the matches replaced and the paths edited.
    @Sendable func replaceInBuffers(_ files: any ToolCaller, targets: [EditorPaneRef], skipped: Set<String>,
                                    _ s: EditorSearchState, _ replacement: String) async throws -> (count: Int, paths: Set<String>) {
        var perPath: [String: Int] = [:]
        for target in targets {
            var pending: Set<EditorTabSubject>?
            for _ in 0..<3 {
                let tabs = await panes.editorSnapshot(in: target.scope, paneId: target.paneId).tabs.filter { t in
                    guard let path = t.path, skipped.contains(path), !t.readOnly else { return false }
                    return pending?.contains(t.subject) ?? true
                }
                if tabs.isEmpty { break }
                let answers = try await replaceTexts(files, tabs.map(\.text), s, replacement)
                let sent = Array(zip(tabs, answers))
                let outcome = await panes.updateEditor(in: target.scope, paneId: target.paneId) { snap -> (done: [String: Int], stale: [EditorTabSubject]) in
                    var done: [String: Int] = [], stale: [EditorTabSubject] = []
                    for (tab, answer) in sent where answer.count > 0 {
                        guard let i = snap.tabs.firstIndex(where: { $0.subject == tab.subject }) else { continue }
                        guard snap.tabs[i].text == tab.text else { stale.append(tab.subject); continue }
                        guard let change = editorReplaceChange(old: tab.text, new: answer.text) else { continue }
                        snap.tabs[i].text = answer.text
                        snap.tabs[i].edits += 1
                        snap.tabs[i].preview = false   // an edit keeps a preview tab
                        let serial = (snap.tabs[i].lastAgentEdit?.serial ?? 0) + 1
                        snap.tabs[i].lastAgentEdit = EditorAgentEdit(serial: serial, range: change.range, text: change.text)
                        if let path = tab.path, done[path] == nil { done[path] = answer.count }
                    }
                    return (done, stale)
                }
                for (path, n) in outcome.done where perPath[path] == nil { perPath[path] = n }
                if outcome.stale.isEmpty { break }
                pending = Set(outcome.stale)
            }
        }
        var count = 0
        for n in perPath.values { count += n }
        return (count, Set(perPath.keys))
    }

    await registry.register(Action(
        name: "editor_replace",
        description: "Replace every match of an editor pane's Search view — its query and switches — with "
            + "replacement (may be empty; with regex, $1, ${name} and $$ expand as Go's regexp.Expand reads "
            + "them), across the files the search covers, searching again first. A file open in any editor "
            + "pane of the window, in any conversation of the project, is edited in its buffer (unsaved; ⌘Z "
            + "undoes it) and its file is left as it is; every other "
            + "file is written. file (absolute) limits it to one file. cancel true stops a replace in flight "
            + "between batches, or an undo between files; what was written stays. Answers replaced, files and failures with the pane's "
            + "state; editor_replace_undo puts back what it wrote. Confined to the active project's roots "
            + "(Invariant 6, Decision 36, Decision 39). Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["replacement": .object(["type": .string("string")]), "file": .object(["type": .string("string")]),
                        "cancel": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_replace")
            if flag(params, "cancel") {
                await panes.updateEditor(paneId: pane) { s in if s.search.replace.inFlight { s.search.replace.cancelRequested = true } }
                return await reply(pane)
            }
            guard let replacement = optionalString(params, "replacement") else {
                throw StandardActionError.missingParam(action: "editor_replace", param: "replacement")
            }
            let only = try await optionalString(params, "file").flatMap { $0.isEmpty ? nil : $0 }
                .asyncMap { try await confine($0, action: "editor_replace").path }
            let files = try requireFiles("editor_replace")
            // Claimed in one turn (Rule 5): one replace per pane. An empty query replaces nothing (ruling 9).
            let claim = await panes.updateEditor(paneId: pane, create: true) { s -> EditorSearchState? in
                guard !s.search.replace.inFlight, !s.search.query.isEmpty else { return nil }
                s.search.replace.text = replacement
                s.search.replace.shown = true
                s.search.replace.inFlight = true
                s.search.replace.cancelRequested = false
                return s.search
            }
            guard let search = claim else { return await reply(pane) }
            // Pre-flight F2: every editor pane the store holds, hidden scopes too, so no open tab's
            // file is written (spec, Open tabs; Decision 39).
            let targets = await panes.editorPanesInEveryScope()
            var open: [String] = []
            for t in targets { open += t.paths }
            var run = EditorReplaceRun()
            var failure: Error?
            var after = ""
            repeat {
                if Task.isCancelled || (await panes.editorSnapshot(paneId: pane).search.replace.cancelRequested) {
                    run.cancelled = true
                    break
                }
                var args = replaceArgs(search, replacement)
                args["skip"] = .array(open.map { .string($0) })
                if let only { args["only"] = .string(only) }
                if !after.isEmpty { args["after"] = .string(after) }
                args["max_files"] = .integer(Int64(editorReplaceBatchFiles))
                let sent = args
                // Its own task (ruling 1): cancelling this handler never cancels a call in flight, whose
                // reply names files already written — the undo needs every one.
                let batch = Task { try await filesTool(files, "files_replace", sent, timeout: MCPClient.mutationReplyTimeout) }
                do {
                    switch try await batch.value {
                    case .failed(let text): failure = EditorFilesError(description: text)
                    case .ok(let o):
                        let b = editorReplaceBatch(from: o)
                        run.add(b)
                        after = b.next
                    }
                } catch { failure = error }
            } while failure == nil && !after.isEmpty
            if failure == nil, !run.cancelled {
                do {
                    let edited = try await replaceInBuffers(files, targets: targets, skipped: run.skipped, search, replacement)
                    run.addBuffers(count: edited.count, paths: edited.paths)
                } catch { failure = error }
            }
            let result = run.result
            let recorded = failure == nil || !result.undo.isEmpty || result.replaced > 0
            await panes.updateEditor(paneId: pane) { s in
                s.search.replace.inFlight = false
                s.search.replace.cancelRequested = false
                if recorded { s.search.replace.last = result }
            }
            // The search runs again to show what is left (spec); its own error lands in the view.
            try? await runSearch(pane, query: search.query, caseSensitive: search.caseSensitive,
                                 wholeWord: search.wholeWord, regex: search.regex)
            if let failure { throw failure }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["replaced"] = .number(Double(result.replaced))
            o["files"] = .number(Double(result.files))
            o["failures"] = editorReplaceFailuresJSON(result.failures)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_replace_undo",
        description: "Undo an editor pane's latest editor_replace: each file it wrote is put back, only while "
            + "that file is exactly as the replace left it (its modification time unchanged); a file changed "
            + "or deleted since is left as it is and listed. Buffer edits are not part of it (⌘Z in their tab). "
            + "One undo is kept, the latest replace's, while the window is open; refused when there is none. "
            + "Answers restored and failures with the pane's state. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_replace_undo")
            let files = try requireFiles("editor_replace_undo")
            let claim = await panes.updateEditor(paneId: pane, create: true) { s -> EditorUndoClaim in
                if s.search.replace.inFlight { return .busy }
                guard let last = s.search.replace.last, last.undoable else { return .nothing }
                s.search.replace.inFlight = true
                s.search.replace.undoing = true           // pre-flight F6: the view says "undoing"
                s.search.replace.cancelRequested = false
                return .claimed(last.undo)
            }
            let records: [EditorReplaceUndoRecord]
            switch claim {
            case .busy: return await reply(pane)               // Rule 5
            case .nothing: throw EditorActionError.nothingToUndo
            case .claimed(let r): records = r
            }
            var restored = 0
            var failures: [EditorReplaceFailure] = []
            var stopped = false
            for r in records {
                // Pre-flight F6: the Cancel the view draws (`editor_replace {cancel}`) lands before the
                // next file; the rest are left as they are and listed.
                if !stopped { stopped = Task.isCancelled || (await panes.editorSnapshot(paneId: pane).search.replace.cancelRequested) }
                if stopped { failures.append(EditorReplaceFailure(path: r.path, error: EditorReplaceFailure.stopped)); continue }
                do {
                    switch try await filesTool(files, "files_read", ["path": .string(r.path)]) {
                    case .failed(let text):
                        failures.append(EditorReplaceFailure(path: r.path, error: text))
                        continue
                    case .ok(let o):
                        guard o["exists"] == .bool(true), Int64(o["mtime"]?.intValue ?? 0) == r.mtime else {
                            failures.append(EditorReplaceFailure(path: r.path, error: EditorReplaceFailure.changedSince))
                            continue
                        }
                    }
                    switch try await filesTool(files, "files_write", ["path": .string(r.path), "text": .string(r.original),
                                                                      "create": .bool(false)]) {
                    case .failed(let text): failures.append(EditorReplaceFailure(path: r.path, error: text))
                    case .ok: restored += 1
                    }
                } catch {
                    failures.append(EditorReplaceFailure(path: r.path, error: error is CancellationError
                                                         ? EditorReplaceFailure.stopped : String(describing: error)))
                }
            }
            let done = (restored: restored, failures: failures)
            await panes.updateEditor(paneId: pane) { s in
                s.search.replace.inFlight = false
                s.search.replace.undoing = false
                s.search.replace.cancelRequested = false
                s.search.replace.last?.undone = true
                s.search.replace.last?.restored = done.restored
                s.search.replace.last?.failures = done.failures
            }
            let q = await panes.editorSnapshot(paneId: pane).search
            if !q.query.isEmpty {
                try? await runSearch(pane, query: q.query, caseSensitive: q.caseSensitive, wholeWord: q.wholeWord, regex: q.regex)
            }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["restored"] = .number(Double(restored))
            o["failures"] = editorReplaceFailuresJSON(failures)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))
```

And beside the file's other private enums:

```swift
private enum EditorUndoClaim: Sendable { case busy, nothing, claimed([EditorReplaceUndoRecord]) }
```

- [ ] **Step 6: Run them; they pass, with the editor suite**

Run: `cd app && ../scripts/swift-test.sh --filter 'Editor|AppWiring|WindowModelPalette'`, then `make app-build`.
Expected: PASS, and WakilApp builds (it reads nothing new yet).

- [ ] **Step 7: Commit**

```bash
gh stack add yehia-khalil/3b-ii-b-2-replace-actions
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "Editor: editor_replace and editor_replace_undo — open tabs edited in their buffers, the rest written, one mtime-guarded undo — and the Replace field's preview (3b-ii-b PR 2)"
```

---

### Task 3: `editor_move_tab`, `editor_tree_reveal`; the window's reveal and middle-click close; ⌘K's command (PR 3)

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorTabs.swift`, `EditorActions.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Modify: `app/Sources/WakilKit/Command/CommandCatalog.swift`
- Modify: `app/Tests/WakilKitTests/AppWiringTests.swift`, `WindowModelPaletteTests.swift`,
  `InvalidationContractTests.swift`, `CommandCatalogTests.swift`
- Test: `app/Tests/WakilKitTests/EditorTabsTests.swift`, `EditorTabMoveRevealTests.swift` (new),
  `WindowModelEditorTests.swift`

**Interfaces:**
- Consumes: `persist`, `treePath`, `updateColumn`, `editorTabIndex` (EditorActions), `askUnsaved`,
  `focusedEditorPane`, `dispatch` (WindowModel).
- Produces:
  - `editorMovingTab(_ s: EditorSnapshot, from: Int, to: Int) -> EditorSnapshot?` — nil when either
    index is out of range or `from == to`; the active tab stays the same tab.
  - `editorTabDropTarget(from: Int, x: Double, y: Double, spans: [ClosedRange<Double>], height: Double) -> Int?` —
    the index the dragged tab `from` moves to when dropped at `x`: over tab k, k; in a gap or past an
    end, the slot's index (the slot before the first tab right of `x`, or the count). nil when `y` is
    outside `0..<height`, or the drop is the tab's own place (pre-flight F4).
  - `EditorTabDrop{from: Int; to: Int}` (Equatable) — a drag's current target, for the line.
  - `editorTabDropX(_ drop: EditorTabDrop, spans: [ClosedRange<Double>]) -> Double` — where the violet
    line draws: past the right edge of tab `to` when it moves right, before its left edge when left.
  - Actions: `editor_move_tab {pane?, from, to}` (control) and `editor_tree_reveal {pane?, path?}` (control).
  - `WindowModel.revealActiveFileInTree(pane: String? = nil) async`,
    `WindowModel.editorTreeRevealRequest: EditorTreeRevealRequest?`, `editorTreeRevealTaken()`,
    `WindowModel.closeEditorTab(pane: String, subject: EditorTabSubject) async`.
  - `EditorTreeRevealRequest{pane: String; path: String; serial: Int}` (public, Equatable, Sendable).
  - `PaletteContext.editorActiveIsFile: Bool` (init parameter, default `false`); catalog command
    `editor.reveal`, *Reveal Active File in Tree*, action `window.editorReveal`.

**Rulings that apply here:** 12, 13, 14, 15.

- [ ] **Step 1: Write the failing tests**

Append to `EditorTabsTests.swift`:

```swift
// Review Focus 5.
@Test func movingATabKeepsTheActiveTabTheSameTab() throws {
    let s = EditorSnapshot(tabs: [.scratch(number: 1, language: "sql"), .scratch(number: 2, language: "sql"),
                                  .scratch(number: 3, language: "sql")], active: 1)
    let moved = try #require(editorMovingTab(s, from: 0, to: 2))
    #expect(moved.tabs.map(\.subject) == [.scratch(number: 2), .scratch(number: 3), .scratch(number: 1)])
    #expect(moved.active == 0)                     // Untitled-2 is still the active tab
    let back = try #require(editorMovingTab(moved, from: 2, to: 0))
    #expect(back.tabs.map(\.subject) == s.tabs.map(\.subject) && back.active == 1)
    #expect(editorMovingTab(s, from: 1, to: 1) == nil)
    #expect(editorMovingTab(s, from: 3, to: 0) == nil)
    #expect(editorMovingTab(s, from: 0, to: 3) == nil)
}

@Test func aDropOverATabMovesTheDraggedTabToThatTabsIndexWhereverOnItTheDropLands() {
    let spans: [ClosedRange<Double>] = [0...100, 102...202, 204...304]
    for x in [204.0, 254, 255, 303] {                                     // any point of tab 2, centre or not
        #expect(editorTabDropTarget(from: 0, x: x, y: 15, spans: spans, height: 36) == 2)
    }
    #expect(editorTabDropTarget(from: 0, x: 60, y: 15, spans: spans, height: 36) == nil)    // its own place
    #expect(editorTabDropTarget(from: 2, x: 10, y: 15, spans: spans, height: 36) == 0)
    #expect(editorTabDropTarget(from: 0, x: 150, y: 15, spans: spans, height: 36) == 1)
    #expect(editorTabDropTarget(from: 1, x: 150, y: 15, spans: spans, height: 36) == nil)
    #expect(editorTabDropTarget(from: 0, x: 60, y: 80, spans: spans, height: 36) == nil)    // off the strip
    #expect(editorTabDropTarget(from: 2, x: 10, y: -4, spans: spans, height: 36) == nil)
}

@Test func aDropInAGapOrPastAnEndTakesTheSlotThere() {
    let spans: [ClosedRange<Double>] = [0...100, 102...202, 204...304]
    #expect(editorTabDropTarget(from: 2, x: 101, y: 15, spans: spans, height: 36) == 1)     // gap before tab 1
    #expect(editorTabDropTarget(from: 0, x: 203, y: 15, spans: spans, height: 36) == 1)     // gap before tab 2
    #expect(editorTabDropTarget(from: 0, x: 101, y: 15, spans: spans, height: 36) == nil)   // before its next: own place
    #expect(editorTabDropTarget(from: 0, x: 900, y: 15, spans: spans, height: 36) == 2)     // past the end
    #expect(editorTabDropTarget(from: 2, x: -5, y: 15, spans: spans, height: 36) == 0)      // before the first
    #expect(editorTabDropTarget(from: 2, x: 900, y: 15, spans: spans, height: 36) == nil)   // after itself, last
}

@Test func theDropLineDrawsOnTheSideAwayFromTheDraggedTab() {
    let spans: [ClosedRange<Double>] = [0...100, 102...202, 204...304]
    #expect(editorTabDropX(EditorTabDrop(from: 0, to: 2), spans: spans) == 305)             // moving right: after it
    #expect(editorTabDropX(EditorTabDrop(from: 2, to: 0), spans: spans) == -1)              // moving left: before it
    #expect(editorTabDropX(EditorTabDrop(from: 0, to: 1), spans: spans) == 203)
    #expect(editorTabDropX(EditorTabDrop(from: 2, to: 1), spans: spans) == 101)
}
```

`EditorTabMoveRevealTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func threeTabs() async throws -> EditorFixture {
    let f = try await editorFixture()
    for p in ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"] {
        await f.files.put(p, "x")
        try await f.dispatch("editor_open", ["path": .string(p)])
    }
    return f
}

@Test func moveTabReordersKeepsTheActiveTabAndPersists() async throws {
    let f = try await threeTabs()
    try await f.dispatch("editor_focus_tab", ["index": .integer(1)])
    try await f.dispatch("editor_move_tab", ["from": .integer(0), "to": .integer(2)])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/b.go", "/p/web/c.ts", "/p/api/a.go"])
    #expect(s.active == 0)
    #expect(await f.layout.editorTabs(id: f.pane)?.map(\.path) == ["/p/api/b.go", "/p/web/c.ts", "/p/api/a.go"])
}

@Test func aMovedOrderComesBackOnRestore() async throws {
    let f = try await threeTabs()
    try await f.dispatch("editor_move_tab", ["from": .integer(2), "to": .integer(0)])
    // A relaunch: the store holds nothing, the layout kept the saved tabs.
    await f.panes.updateEditor(paneId: f.pane) { s in s.tabs = []; s.active = nil }
    try await f.dispatch("editor_restore")
    #expect(await f.snapshot().tabs.map(\.path) == ["/p/web/c.ts", "/p/api/a.go", "/p/api/b.go"])
}

@Test func aMoveOutOfRangeIsRefusedAndMovesNothing() async throws {
    let f = try await threeTabs()
    await #expect(throws: EditorActionError.noTab(action: "editor_move_tab")) {
        try await f.dispatch("editor_move_tab", ["from": .integer(5), "to": .integer(0)])
    }
    #expect(await f.snapshot().tabs.map(\.path) == ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"])
}

@Test func revealOpensEveryFolderAboveTheActiveFile() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/app/Models/Booking.php", "x")
    try await f.dispatch("editor_open", ["path": .string("/p/api/app/Models/Booking.php")])
    try await f.dispatch("editor_tree_reveal")
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app", "/p/api/app/Models"])
}

@Test func revealTakesAPathAndOpensFoldersOnly() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_tree_reveal", ["path": .string("/p/web/src/r.ts")])
    let c = await f.snapshot().column
    #expect(c?.open == ["/p/web", "/p/web/src"])
    #expect(c?.shown == EditorColumnState.initial.shown)      // the operator's view is not moved
}

@Test func revealRefusesAPathOutsideTheRootsAndNeedsAFileTab() async throws {
    let f = try await editorFixture()
    do {
        try await f.dispatch("editor_tree_reveal", ["path": .string("/etc/hosts")])
        Issue.record("expected the refusal")
    } catch { #expect(String(describing: error).contains("Invariant 6")) }
    await #expect(throws: EditorActionError.noTab(action: "editor_tree_reveal")) { try await f.dispatch("editor_tree_reveal") }
    try await f.dispatch("editor_new_scratch")
    await #expect(throws: EditorActionError.notAFile(action: "editor_tree_reveal")) { try await f.dispatch("editor_tree_reveal") }
}
```

In `WindowModelEditorTests.swift`, inside the suite:

```swift
    @Test func revealShowsFilesOpensTheFoldersAndAsksThePaneToSelectTheRow() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/app/a.go", "x")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/app/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.revealActiveFileInTree(pane: pane)
        #expect(model.editor(pane)?.column?.shown == true && model.editor(pane)?.column?.view == .files)
        #expect(model.editor(pane)?.column?.open == ["/p/api", "/p/api/app"])
        #expect(model.editorTreeRevealRequest?.pane == pane && model.editorTreeRevealRequest?.path == "/p/api/app/a.go")
        #expect(model.editorColumnFocusRequest == nil, "the keyboard stays where it was (Rule 6)")
        model.editorTreeRevealTaken()
        #expect(model.editorTreeRevealRequest == nil)
    }

    @Test func revealWithAScratchInFrontDoesNothing() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.revealActiveFileInTree(pane: pane)
        #expect(model.editorTreeRevealRequest == nil && model.editor(pane)?.column == nil)
    }

    @Test func anOrgSwitchClearsAPendingRevealRequest() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "x")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        await model.revealActiveFileInTree()
        try #require(model.editorTreeRevealRequest != nil)
        await model.invalidateForOrgChange()
        #expect(model.editorTreeRevealRequest == nil)
    }

    @Test func aMiddleClickClosesACleanTabAndAsksAboutADirtyOne() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 1, text: "typed", basis: 0)
        await model.closeEditorTab(pane: pane, subject: .scratch(number: 1))
        #expect(model.editor(pane)?.tabs.map(\.subject) == [.scratch(number: 2)])
        await model.closeEditorTab(pane: pane, subject: .scratch(number: 2))
        #expect(model.unsavedPrompt?.intent == .closeTab(pane: pane, subject: .scratch(number: 2)))
        #expect(model.editor(pane)?.tabs.count == 1)
    }

    @Test func theRevealCommandIsOfferedOnlyWithAFileTabInFront() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await model.newScratch()
        #expect(!(await model.paletteContext().editorActiveIsFile))
        await files.put("/p/api/a.go", "x")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshPanes()
        #expect(await model.paletteContext().editorActiveIsFile)
    }
```

`CommandCatalogTests.swift`: the `window.` list becomes `["api.send", "editor.reveal"]`, and:

```swift
@Test func revealIsAnEditorCommandOnlyWithAFileInFront() {
    var c = ctx("editor")
    #expect(!CommandCatalog.entries(for: c).map(\.title).contains("Reveal Active File in Tree"))
    c.editorActiveIsFile = true
    #expect(CommandCatalog.entries(for: c).map(\.title).contains("Reveal Active File in Tree"))
}
```

(`ctx(_:)` is the file's existing helper building a `PaletteContext` with a focused pane of that kind.)

The pinned lists gain `editor_move_tab` and `editor_tree_reveal`: `AppWiringTests.swift` (sorted),
`registeredBeforeThePalette`, and — both `.control` — `agentToolsBeforeThePalette` as
`"mcp__wakil__editor_move_tab", "mcp__wakil__editor_tree_reveal"`.

`InvalidationContractTests.swift`'s `orgDerived` gains, after `"editorColumnFocusRequest"`:

```swift
    // 3b-ii-b: the reveal button's or ⌘K's pending selection names an outgoing pane id the next org
    // reuses. Cleared (WindowModelEditorTests.anOrgSwitchClearsAPendingRevealRequest).
    "editorTreeRevealRequest",
```

- [ ] **Step 2: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorTabs|EditorTabMoveReveal|WindowModelEditor|CommandCatalog|InvalidationContract'`
Expected: compile failure — `editorMovingTab`, `revealActiveFileInTree`, `editorActiveIsFile` undefined.

- [ ] **Step 3: Implement**

`EditorTabs.swift`:

```swift
/// `s` with tab `from` moved to `to` (0-based, strip order), the active tab still the same tab
/// (Review Focus 5). nil when either index is outside the strip, or nothing moves.
public func editorMovingTab(_ s: EditorSnapshot, from: Int, to: Int) -> EditorSnapshot? {
    guard s.tabs.indices.contains(from), s.tabs.indices.contains(to), from != to else { return nil }
    var out = s
    let active = s.active.flatMap { s.tabs.indices.contains($0) ? s.tabs[$0].subject : nil }
    out.tabs.insert(out.tabs.remove(at: from), at: to)
    out.active = active.flatMap { a in out.tabs.firstIndex { $0.subject == a } }
    return out
}

/// The index tab `from` moves to when dropped at (`x`, `y`) in the strip, or nil for no move.
/// Over a tab k: k, wherever on it — the usual tab-strip rule, so a drop needs no exact point
/// (ruling 14, pre-flight F4). In a gap or past an end: the slot there (before the first tab right
/// of `x`, else the count), as the index `from` ends at; its own place is nil. nil off the strip.
public func editorTabDropTarget(from: Int, x: Double, y: Double, spans: [ClosedRange<Double>], height: Double) -> Int? {
    guard y >= 0, y < height, spans.indices.contains(from) else { return nil }
    if let k = spans.firstIndex(where: { $0.contains(x) }) { return k == from ? nil : k }
    let slot = spans.firstIndex { $0.lowerBound > x } ?? spans.count
    guard slot != from, slot != from + 1 else { return nil }
    return slot > from ? slot - 1 : slot
}

/// A drag's current target: tab `from` would move to index `to`.
public struct EditorTabDrop: Sendable, Equatable {
    public var from: Int
    public var to: Int
    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// The x the violet drop line draws at: just past the right edge of tab `to` when the dragged tab
/// moves right, just before its left edge when it moves left — the side away from where it came from.
public func editorTabDropX(_ drop: EditorTabDrop, spans: [ClosedRange<Double>]) -> Double {
    guard spans.indices.contains(drop.to) else { return 0 }
    return drop.to > drop.from ? spans[drop.to].upperBound + 1 : spans[drop.to].lowerBound - 1
}
```

`EditorActions.swift`: lift `editor_tree_expand`'s chain-and-heavy-load body into a local function both
actions call (its handler then calls it with `t`):

```swift
    /// Opens `rel` under `root` in the pane's tree, with every folder above it, loading heavy ones
    /// on the way (3b-ii's `editor_tree_expand`, shared with `editor_tree_reveal`).
    @Sendable func openChain(_ pane: String, root: String, rel: String) async {
        var chain = [root]
        var acc = root
        for part in rel.split(separator: "/") { acc += "/\(part)"; chain.append(acc) }
        let opening = chain
        await updateColumn(pane) { c in for p in opening where !c.open.contains(p) { c.open.append(p) } }
        // … editor_tree_expand's existing `if let fileLists { … }` heavy-folder block, with t.root → root
        //   and t.rel → rel …
    }
```

Then, after `editor_tree_collapse`:

```swift
    await registry.register(Action(
        name: "editor_tree_reveal",
        description: "Open every folder above path (absolute; default: the pane's active file) in an editor "
            + "pane's file tree. It opens folders only: the tree's selection and scroll are the operator's, "
            + "which the reveal button and ⌘K's Reveal Active File in Tree move. " + treeRefusal,
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree_reveal")
            let raw: String
            if let p = optionalString(params, "path"), !p.isEmpty {
                raw = p
            } else {
                let snap = await panes.editorSnapshot(paneId: pane)
                guard let i = editorTabIndex(snap, path: nil) else { throw EditorActionError.noTab(action: "editor_tree_reveal") }
                guard let p = snap.tabs[i].path else { throw EditorActionError.notAFile(action: "editor_tree_reveal") }
                raw = p
            }
            let t = try await treePath(raw, action: "editor_tree_reveal")
            await openChain(pane, root: t.root, rel: (t.rel as NSString).deletingLastPathComponent)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_move_tab",
        description: "Move an editor pane's tab from index from to index to (0-based, strip order); the active "
            + "tab stays the same tab. The order is the pane's saved tab order, kept across a relaunch.",
        kind: .control, audience: .agentReachable,
        schema: schema(["from": .object(["type": .string("integer")]), "to": .object(["type": .string("integer")])],
                       required: ["from", "to"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_move_tab")
            guard let from = jsonObject(params)?["from"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_move_tab", param: "from")
            }
            guard let to = jsonObject(params)?["to"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_move_tab", param: "to")
            }
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                if from == to { return s.tabs.indices.contains(from) }
                guard let moved = editorMovingTab(s, from: from, to: to) else { return false }
                s = moved
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_move_tab") }
            await persist(pane)
            return await reply(pane)
        }))
```

`WindowModel.swift`, in `// MARK: Editor`:

```swift
    /// The reveal button's or ⌘K's row to select: the pane's tree selects it once its row is drawn,
    /// scrolls to it, and leaves the keyboard where it is (Rule 6). Only the operator's reveal sets it;
    /// the agent's `editor_tree_reveal` opens folders only.
    public private(set) var editorTreeRevealRequest: EditorTreeRevealRequest?

    /// The pane selected the revealed row: the request is spent.
    public func editorTreeRevealTaken() { editorTreeRevealRequest = nil }

    /// The reveal button and ⌘K's *Reveal Active File in Tree* (3b-ii-b): Files shown, every folder
    /// above the active file opened, its row selected. Nothing with no file tab in front.
    public func revealActiveFileInTree(pane: String? = nil) async {
        guard let pane = pane ?? focusedEditorPane(), let s = editor(pane), let i = s.active, i < s.tabs.count,
              let path = s.tabs[i].path else { return }
        let column = s.column ?? editorColumnDefault
        if !(column.shown && column.view == .files) {
            let shown: JSONValue = .object(["pane": .string(pane), "view": .string("files"), "shown": .bool(true)])
            guard await dispatch("editor_tree", shown) != nil else { return }
        }
        guard await dispatch("editor_tree_reveal", .object(["pane": .string(pane), "path": .string(path)])) != nil else { return }
        await refreshPanes()
        editorTreeRevealRequest = EditorTreeRevealRequest(pane: pane, path: path, serial: (editorTreeRevealRequest?.serial ?? 0) + 1)
    }

    /// A middle-click on a tab (3b-ii-b): ⌘W's rule for that one tab — a clean tab closes, a dirty one
    /// asks Save / Don't Save / Cancel. By subject, never by position.
    public func closeEditorTab(pane: String, subject: EditorTabSubject) async {
        guard let s = editor(pane), let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
        if s.tabs[i].dirty {
            askUnsaved(.closeTab(pane: pane, subject: subject), titles: [editorTabTitles(s.tabs)[i]])
            return
        }
        // No discard: a keystroke landing between the check and the close is refused, never dropped.
        var params: [String: JSONValue] = ["pane": .string(pane)]
        switch subject {
        case .file(let path, _): params["path"] = .string(path)
        case .scratch(let n): params["scratch"] = .integer(Int64(n))
        }
        _ = await dispatch("editor_close", .object(params))
        await refreshLayout()
        await refreshPanes()
    }
```

Beside `editorColumnFocusRequest = nil` in the org-change reset (WindowModel.swift:1876):
`editorTreeRevealRequest = nil`.

Beside `EditorColumnFocusRequest`:

```swift
/// The operator's reveal asking a pane's tree to select and scroll to a file's row (`WindowModel.editorTreeRevealRequest`).
public struct EditorTreeRevealRequest: Sendable, Equatable {
    public var pane: String
    public var path: String
    /// Bumps per request, so the same file revealed twice is two requests.
    public var serial: Int
    public init(pane: String, path: String, serial: Int) {
        self.pane = pane
        self.path = path
        self.serial = serial
    }
}
```

In `paletteContext()`:

```swift
        let editorActiveIsFile: Bool = {
            guard let f = focused, f.kind == "editor", let s = editor(f.id), let i = s.active, i < s.tabs.count else { return false }
            return s.tabs[i].path != nil
        }()
```

passed as `editorActiveIsFile: editorActiveIsFile`. In `paletteDispatch`, beside `"window.apiSend"`:

```swift
        case "window.editorReveal":
            await revealActiveFileInTree(pane: value("pane"))
            return nil
```

`CommandCatalog.swift`: `PaletteContext` gains `public var editorActiveIsFile: Bool` with the init
parameter `editorActiveIsFile: Bool = false`. The catalog, after `editor.language`:

```swift
        // 3b-ii-b. The window's: it shows Files, opens the folders and selects the row, which no one
        // dispatch does (`WindowModel.revealActiveFileInTree`). Hidden without a file tab in front.
        pane("editor.reveal", "Reveal Active File in Tree", "editor", "window.editorReveal",
             available: { $0.editorActiveIsFile }),
```

- [ ] **Step 4: Run them; they pass, with everything the window touches**

Run: `cd app && ../scripts/swift-test.sh --filter 'Editor|WindowModel|CommandCatalog|InvalidationContract|AppWiring|Palette'`,
then `make app-build`.
Expected: PASS; WakilApp builds.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-b-3-tabs-reveal
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "Editor: editor_move_tab and editor_tree_reveal; the window's reveal, middle-click close and ⌘K's Reveal Active File in Tree (3b-ii-b PR 3)"
```

---

### Task 4: Drawing — the Replace field and preview, the buttons and result line, reveal, tab drag, middle-click (PR 4)

**Files:**
- Create: `app/Sources/WakilApp/EditorMiddleClick.swift`
- Modify: `app/Sources/WakilApp/EditorColumn.swift`, `EditorPane.swift`, `Canvas.swift`

**Interfaces:**
- Consumes: Task 2's `EditorReplaceState`, `editorReplacePreviewSpans`, `editorReplaceSummary`,
  `editorReplaceAvailable`, the `replace` param of `editor_search`, `editor_replace` (`cancel`, `file`),
  `editor_replace_undo`; Task 3's `editorTabDropTarget`, `EditorTabDrop`, `editorTabDropX`,
  `editor_move_tab`, `revealActiveFileInTree`, `editorTreeRevealRequest`, `editorTreeRevealTaken`,
  `closeEditorTab`; `EditorDebounce` (3b-ii).
- Produces, as accessibility identifiers for e2e:
  - `editor.search.replaceToggle`, `editor.search.replace` (the field), `editor.search.replaceAll`;
  - `editor.search.replaceFile:<root name>/<path>` on each file group's header;
  - `editor.replace.busy` (the tick), `editor.replace.cancel`;
  - `editor.replace.result` (container), `editor.replace.undo`, `editor.replace.failure` (each failure line);
  - `editor.tree.reveal`;
  - `editor.tab.middleClick` (the middle-button catcher over each tab).

WakilApp has no test target. This task's checks are Task 5's e2e and the walk. Every decision it makes
is a Task 2–3 function, which already has tests.

- [ ] **Step 1: Pass the new inputs from Canvas**

In `Canvas.swift`'s `EditorPane(...)` call, add:

```swift
                    revealInTree: { await model.revealActiveFileInTree(pane: pane.id) },
                    revealRequest: model.editorTreeRevealRequest.flatMap { $0.pane == pane.id ? $0 : nil },
                    revealTaken: { model.editorTreeRevealTaken() },
                    closeTab: { subject in await model.closeEditorTab(pane: pane.id, subject: subject) },
```

`EditorPane` gains those four `let`s (`revealInTree: () async -> Void`, `revealRequest:
EditorTreeRevealRequest?`, `revealTaken: () -> Void`, `closeTab: (EditorTabSubject) async -> Void`)
and `@State private var pendingReveal: String?`. It hands the column:

```swift
                    EditorColumn(column: column, rows: treeRows, pendingRoots: roots.filter { files.listings[$0] == nil },
                                 search: snapshot.search, paneWidth: geo.size.width, dispatch: dispatch,
                                 canReveal: activeTab?.path != nil,
                                 reveal: { Task { await revealInTree() } },
                                 selected: $treeSelected, selectedResult: $resultSelected,
                                 focusWanted: $columnFocusWanted, hasKeyboard: $columnHasKeyboard,
                                 pendingReveal: $pendingReveal)
```

and takes the request as it takes the column's focus request:

```swift
        .onAppear { takeColumnFocusRequest(); takeRevealRequest() }
        .onChange(of: revealRequest) { _, _ in takeRevealRequest() }
```

```swift
    /// The reveal asked this pane's tree to select a file's row; the column selects it once drawn.
    private func takeRevealRequest() {
        guard let r = revealRequest else { return }
        pendingReveal = r.path
        revealTaken()
    }
```

- [ ] **Step 2: The reveal button and the revealed row**

`EditorColumn` gains `let canReveal: Bool`, `let reveal: () -> Void` and `@Binding var pendingReveal:
String?`. In `header`, after `Spacer()`:

```swift
            if column.view == .files {
                Button(action: reveal) { Image(systemName: "scope").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .disabled(!canReveal)
                    .opacity(canReveal ? 0.9 : 0.35)
                    .help(canReveal ? "Reveal Active File in Tree" : "No file tab in front: nothing to reveal")
                    .accessibilityIdentifier("editor.tree.reveal")
            }
```

The revealed row is selected once it is among `rows` (the folders open a turn after the action), never
taking the keyboard (Rule 6); the tree's existing `.onChange(of: selected)` scrolls to it:

```swift
        .onChange(of: rows) { old, now in
            selected = editorTreeSelection(after: selected, previous: old, now: now)
            takeReveal(now)
        }
        .onChange(of: pendingReveal) { _, _ in takeReveal(rows) }
```

and in `.onAppear`, after `takeWantedKeyboard`, `takeReveal(rows)`:

```swift
    private func takeReveal(_ now: [EditorTreeRow]) {
        guard let p = pendingReveal, now.contains(where: { $0.id == p }) else { return }
        pendingReveal = nil
        selected = p
    }
```

- [ ] **Step 3: The Replace field, the buttons, the tick and the result line**

`EditorColumn` gains:

```swift
    @State private var replaceText = ""
    @State private var replaceDebounce = EditorDebounce(delay: .milliseconds(250))
    /// The field's text this column last sent (or took from the store), as `sent` is for the query.
    @State private var replaceSent: String?
    @State private var hoveredFile: String?
    @FocusState private var replaceFocused: Bool
```

In the query `HStack`, first, before the `TextField`:

```swift
                Button {
                    let opening = !search.replace.shown
                    Task {
                        await dispatch("editor_search", ["replace": opening ? .string(replaceText) : .null])
                        if opening { replaceFocused = true }          // Rule 3
                    }
                } label: {
                    Image(systemName: search.replace.shown ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                .help("Replace")
                .accessibilityIdentifier("editor.search.replaceToggle")
```

Under the query row, while `search.replace.shown`:

```swift
            if search.replace.shown {
                HStack(spacing: 6) {
                    TextField("Replace", text: $replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.text)
                        .focused($replaceFocused)
                        // Rule 2: the preview follows the field after a pause; no Enter needed.
                        .onChange(of: replaceText) { _, t in
                            guard t != replaceSent else { replaceDebounce.cancel(); return }
                            replaceDebounce.schedule {
                                replaceSent = t
                                await dispatch("editor_search", ["replace": .string(t)])
                            }
                        }
                        .accessibilityIdentifier("editor.search.replace")
                    // Rule 1: neither button asks; the replace is undoable.
                    Button("Replace All") { replaceAll(file: nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text)
                        .disabled(!editorReplaceAvailable(search))
                        .opacity(editorReplaceAvailable(search) ? 1 : 0.4)
                        .accessibilityIdentifier("editor.search.replaceAll")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(EditorPaneStyle.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 6)
            }
            if search.replace.inFlight {
                HStack(spacing: 8) {
                    // Pre-flight F6: an undo says "undoing", and its Cancel stops it between files.
                    let doing = search.replace.undoing ? "undoing" : "replacing"
                    EditorBusyTick(label: doing, identifier: "editor.replace.busy")
                    Text(doing).font(.system(size: 10.5)).foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                    // Rule 4: a replace in flight can be stopped (what was written stays and can be undone),
                    // and so can an undo (the files it has not reached stay as the replace left them).
                    Button("Cancel") { Task { await dispatch("editor_replace", ["cancel": .bool(true)]) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                        .accessibilityIdentifier("editor.replace.cancel")
                }
                .padding(.horizontal, 12)
            } else if let last = search.replace.last {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text(editorReplaceSummary(last))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                        if last.undoable {
                            Button("Undo replace") { Task { await dispatch("editor_replace_undo", [:]) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(EditorPaneStyle.text)
                                .accessibilityIdentifier("editor.replace.undo")
                        }
                    }
                    .padding(.horizontal, 12)
                    // Rule 8: each file that failed, with its error whole.
                    ForEach(Array(last.failures.enumerated()), id: \.offset) { _, f in
                        searchLine("\(f.path): \(f.error)", opacity: 0.85).accessibilityIdentifier("editor.replace.failure")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor.replace.result")
            }
```

`.onAppear` also sets `replaceSent = search.replace.text; replaceText = search.replace.text`, and the
agent's replace shows its text unless the operator is typing (the query field's rule):

```swift
        .onChange(of: search.replace.text) { old, now in
            guard now != replaceSent, replaceText == old else { return }
            replaceSent = now
            replaceText = now
        }
```

```swift
    /// Replace All, or Replace in this file (`file` absolute). The pending preview is not waited for:
    /// the replace sends the field's text itself.
    private func replaceAll(file: String?) {
        replaceDebounce.cancel()
        replaceSent = replaceText
        var params: [String: JSONValue] = ["replacement": .string(replaceText)]
        if let file { params["file"] = .string(file) }
        Task { await dispatch("editor_replace", params) }
    }
```

- [ ] **Step 4: The preview in each result line, and Replace in this file**

`resultText(_:)` draws the preview from the pane's answer while the toggle is open; otherwise it marks
matches as before:

```swift
    private func resultText(_ m: EditorSearchMatch) -> AttributedString {
        var line = AttributedString("\(m.line)  ")
        line.foregroundColor = EditorPaneStyle.text.opacity(0.45)
        if search.replace.shown, let edits = search.replace.preview[m.preview] {
            var out = line
            for span in editorReplacePreviewSpans(m.preview, edits: edits) {
                switch span {
                case .kept(let s):
                    var a = AttributedString(s); a.foregroundColor = EditorPaneStyle.text.opacity(0.72); out += a
                case .removed(let s):
                    var a = AttributedString(s)
                    a.foregroundColor = EditorPaneStyle.text.opacity(0.55)
                    a.strikethroughStyle = .single
                    out += a
                case .inserted(let s):
                    var a = AttributedString(s)
                    a.foregroundColor = EditorPaneStyle.violet
                    a.backgroundColor = EditorPaneStyle.violet.opacity(0.18)
                    out += a
                }
            }
            return out
        }
        // … the existing marked preview, unchanged …
    }
```

`groupHeader` gains a trailing *Replace in this file* button on file headers. It is always in the
accessibility tree, so a press can reach it; it shows on hover and when the selected result is in that
file:

```swift
    private func groupHeader(_ title: String, key: String, id: String, root: Bool) -> some View {
        let open = !collapsed.contains(key)
        let fileSelected = !root && selectedResult.map { $0.hasPrefix(id + ":") } == true
        let showReplace = !root && search.replace.shown
        return HStack(spacing: 5) {
            // … the existing chevron and title …
            if showReplace {
                Spacer(minLength: 4)
                Button("Replace in this file") { replaceAll(file: key) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text)
                    .disabled(!editorReplaceAvailable(search))
                    .opacity(hoveredFile == key || fileSelected ? (editorReplaceAvailable(search) ? 1 : 0.4) : 0)
                    .allowsHitTesting(hoveredFile == key || fileSelected)
                    .accessibilityIdentifier("editor.search.replaceFile:\(id)")
            }
        }
        // … the existing modifiers …
        .onHover { inside in hoveredFile = inside ? key : (hoveredFile == key ? nil : hoveredFile) }
    }
```

Task 5's `3b-ii-b-replace-file.jsonl` selects the file's result before pressing, so it presses a shown
button; if a measured run finds SwiftUI leaving an opacity-0 button out of the tree even then, draw it
at `0.35` instead of `0` when neither hovered nor selected, and say so in the PR.

`key` for a file header is `"\(root)/\(path)"`: the absolute path `editor_replace`'s `file` takes. `id`
is `"<root name>/<path>"`, hoisted for the identifier harvest. The header's `.accessibilityElement(children:
.combine)` becomes `.accessibilityElement(children: root ? .combine : .contain)` (pre-flight F5): only a
**file** header holds a button that must keep its own identifier. A root header carries no button, and
`3b-ii-search.jsonl` clicks it (`editor.search.group:e2e-api`), so it stays `.combine`, where its
`accessibilityAction` is known to answer AXPress. The header's own `editor.search.group:<…>` stays on
the container with its `.isButton` trait and `accessibilityAction`.

Rule 6: a replace keeps the results' scroll and selection — `selectedResult` is view state keyed by
`root/path:line:column` and survives the re-run where its row survives; nothing here resets it.

- [ ] **Step 5: Tab drag with its drop line**

`EditorPane` gains:

```swift
    /// Each tab's horizontal span in the strip's space, reported by the tabs themselves.
    @State private var tabSpans: [Int: ClosedRange<Double>] = [:]
    /// Where a dragged tab would land now, while a drag is over the strip.
    @State private var drop: EditorTabDrop?
```

```swift
private struct EditorTabSpansKey: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<Double>] = [:]
    static func reduce(value: inout [Int: ClosedRange<Double>], nextValue: () -> [Int: ClosedRange<Double>]) {
        value.merge(nextValue()) { _, b in b }
    }
}
```

The strip's inner `HStack(spacing: 2)` gets `.coordinateSpace(name: "editor.tabs")`,
`.onPreferenceChange(EditorTabSpansKey.self) { tabSpans = $0 }`, and the drop line:

```swift
                .overlay(alignment: .topLeading) {
                    if let drop {
                        Rectangle().fill(EditorPaneStyle.violet).frame(width: 2, height: 22)
                            .offset(x: editorTabDropX(drop, spans: orderedSpans) - 1, y: 4)
                            .allowsHitTesting(false)
                    }
                }
```

```swift
    private var orderedSpans: [ClosedRange<Double>] {
        snapshot.tabs.indices.map { tabSpans[$0] ?? 0...0 }
    }
```

Each `tabView` reports its span and takes the drag. A drag needs 4 pt of movement, so a click stays a
tab click (ruling 14):

```swift
        .background(GeometryReader { g in
            let f = g.frame(in: .named("editor.tabs"))
            Color.clear.preference(key: EditorTabSpansKey.self, value: [index: Double(f.minX)...Double(f.maxX)])
        })
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("editor.tabs"))
            .onChanged { g in
                drop = editorTabDropTarget(from: index, x: g.location.x, y: g.location.y, spans: orderedSpans, height: 30)
                    .map { EditorTabDrop(from: index, to: $0) }
            }
            .onEnded { g in
                defer { drop = nil }
                // Off the strip, or on its own place: nothing moves (spec).
                guard let to = editorTabDropTarget(from: index, x: g.location.x, y: g.location.y, spans: orderedSpans, height: 30)
                else { return }
                Task { await dispatch("editor_move_tab", ["from": .integer(Int64(index)), "to": .integer(Int64(to))]) }
            })
```

`height: 30` is the tab's own frame height, so the strip's vertical band is the tabs' band (the
`editor.tabs` space starts at the tabs' top).

- [ ] **Step 6: Middle-click**

`EditorMiddleClick.swift`:

```swift
import AppKit
import SwiftUI

/// A middle-click catcher over one tab (3b-ii-b). SwiftUI has no middle-button gesture, so this
/// `NSView` takes `otherMouseDown` with `buttonNumber == 2`. It is hit only by a middle-button event:
/// every other click and drag passes through to the tab's own gestures.
struct EditorMiddleClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.action = action
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .otherMouseDown || e.type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseDown(with: event) }
        }
    }
}
```

On `tabView`, after the tap gesture:

```swift
        // ⌘W's path for this tab: a clean tab closes, a dirty one asks (3b-i's prompt).
        .overlay(EditorMiddleClick { Task { await closeTab(tab.subject) } }
            .accessibilityIdentifier("editor.tab.middleClick"))
```

- [ ] **Step 7: Build, then look at it once**

Run: `make build && make app-bundle`
Expected: both succeed.

Then the controller launches the bundle once against the §0 project of Task 5's runbook. Ask the
operator first: the GUI is shared (memory `shared-gui-between-sessions`). Confirm:
- the ▸ toggle, the field and a struck-through / violet preview line;
- *Replace in this file* appearing on hover;
- the reveal button selecting a row;
- a tab drag showing the violet line;
- a middle-click closing a clean tab.

Fix anything that does not draw before committing.

- [ ] **Step 8: Commit**

```bash
gh stack add yehia-khalil/3b-ii-b-4-ui
git add app/Sources/WakilApp
git commit -m "Editor pane: the Replace field and its preview, Replace All and in this file, Undo replace, the reveal button, tab drag and middle-click close (3b-ii-b PR 4)"
```

---

### Task 5: Charter, e2e checks, the acceptance runbook (PR 5)

**Files:**
- Modify: `docs/wakil/decisions.md`:
  - **Decision 39**, after 38, in its numbered style (text below);
  - the *Invariant 6* section's *"2026-10-11 — a file write inside the project's roots"*: its first
    sentence, *"Local files only, through `wakil-files`'s `files_write`, whole text by atomic rename, …"*,
    becomes *"Local files only, through `wakil-files`'s `files_write` (and, since 3b-ii-b,
    `files_replace`), whole text by atomic rename, …"* (pre-flight F8: `files_write` is no longer the
    only tool that writes); its last sentence becomes *"The editor's `editor_save`, and since 3b-ii-b
    `editor_replace` and `editor_replace_undo` (Decision 39), are the actions that reach it."*
- Modify: `docs/wakil/design-language.md` §11, the editor's left column bullet (text below).
- Modify: `docs/superpowers/specs/2026-10-13-3b-ii-editor-tree-design.md`: the roadmap table gains,
  after the 3b-ii row, `| **3b-ii-b** | Replace across the project, reveal the open file in the tree, move tabs, middle-click close | 4, 6 (orient) |`.
- Modify: `docs/architecture/wakilkit.md`: `EditorReplace.swift` in the Editor list and in the
  pane-kinds table row; `EditorActions.swift`'s bullet gains *"3b-ii-b adds `editor_replace` (batched
  `files_replace`, open tabs edited in their buffers, `cancel`), `editor_replace_undo`,
  `editor_move_tab` and `editor_tree_reveal`, and `editor_search`'s `replace`"*; `EditorTabs.swift`'s
  gains the move and drop-target rules. `docs/architecture/wakilapp.md`'s editor row gains
  `EditorMiddleClick.swift`.
- Modify: `e2e/driver/seedgit.go` (`searchHaystackChecks` gains `"3b-ii-b-replace-cancel.jsonl"`;
  `searchBulk()` gains `bulk/zz-marker.txt`) and `e2e/driver/seed_test.go`
  (`TestSeedWritesTheSearchHaystackOnlyWhenAsked`: the committed-file pin becomes `searchBulkFiles+1`,
  the extra file is asserted by name, and its content joins the query-hygiene loop; pre-flight F9).
- Create: `e2e/checks/seeded/3b-ii-b-replace-all.jsonl`, `3b-ii-b-replace-undo.jsonl`,
  `3b-ii-b-replace-file.jsonl`, `3b-ii-b-replace-cancel.jsonl`, `3b-ii-b-reveal.jsonl`,
  `3b-ii-b-tab-move.jsonl`.
- Modify: `e2e/checks/uncoverable.tsv`, with the lines below.
- Create: `docs/wakil/phase-3b-ii-b-acceptance.md`.
- Proofs: `e2e/checks/proofs/3b-ii-b-*.json` (written by `make e2e-new`).

- [ ] **Step 1: The charter**

`decisions.md`, after 38:

```markdown
39. **A replace across many files is Decision 36's file write, one file at a time.**
    *(2026-10-14, operator, during the 3b-ii-b design —
    `docs/superpowers/specs/2026-10-14-3b-ii-b-editor-replace-tabs-design.md`.)*
    `editor_replace` writes every match of the Search view's query in the files the search covers,
    each file whole and atomically through `wakil-files` (`files_replace`), confined to the roots after
    symlinks resolve. Its price is *allow* in production and outside it, for the operator and the agent
    alike, as `editor_save`'s is: it reaches nothing a bare harness's file tools could not. **It never
    writes a file open in a tab:** that file's buffer is edited instead, unsaved, so work the operator
    has not saved is never overwritten. **Its undo is in memory and conditional:** one, the latest
    replace's, for the window's life; it puts a file back only while the file is exactly as the replace
    left it (its modification time unchanged), and lists the rest. Replace All asks nothing (Rule 1):
    it is undoable.
    *Reverse if:* a replace is found to have overwritten work the operator had not saved — then the
    price becomes *gate*.
```

`design-language.md` §11, under **Search** in the left column's bullets, add:

```markdown
  - **Replace** (3b-ii-b) — a ▸ beside the query opens a Replace field; each result line then shows
    its match struck through and the replacement in violet. *Replace All* and a file group's *Replace
    in this file* ask nothing (Decision 39): a file open in a tab is edited in its buffer, the rest are
    written, and one line — *Replaced 37 in 12 files · Undo replace* — offers the undo, which leaves
    any file changed since.
```

and after the **Files** bullet: *"A reveal button in its header (and ⌘K's *Reveal Active File in
Tree*) opens the folders above the active file and selects its row; the tree never follows the
active file by itself."* After **The preview tab**: *"Tabs move by dragging along their own strip (a
violet line marks the drop) and close on a middle-click, as ⌘W closes them."*

- [ ] **Step 2: Write the checks**

Every check starts with the git project and a scratch tab, as 3b-ii's do. Files are made through the
editor, so no seed changes but the cancel check's haystack.

`3b-ii-b-replace-all.jsonl` — Replace All with one target open and dirty; the agent's channel is
`3b-ii-b-replace-undo.jsonl`'s:

```jsonl
{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}
{"expect":{"tree":"contains","text":"e2e-git"}}
{"dispatch":{"action":"editor_new_scratch","params":{}}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"1"}}
{"dispatch":{"action":"editor_replace_range","params":{"pane":"editor-1","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":1}},"text":"swapme in a"}}}
{"dispatch":{"action":"editor_save","params":{"pane":"editor-1","as":"{fixtureRoot}/e2e-api/swap-a"}}}
{"dispatch":{"action":"editor_new_scratch","params":{"pane":"editor-1"}}}
{"dispatch":{"action":"editor_replace_range","params":{"pane":"editor-1","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":1}},"text":"swapme in b"}}}
{"dispatch":{"action":"editor_save","params":{"pane":"editor-1","as":"{fixtureRoot}/e2e-api/swap-b"}}}
{"dispatch":{"action":"editor_close","params":{"pane":"editor-1","path":"{fixtureRoot}/e2e-api/swap-b"}}}
{"dispatch":{"action":"editor_new_scratch","params":{"pane":"editor-1"}}}
{"dispatch":{"action":"editor_replace_range","params":{"pane":"editor-1","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":1}},"text":"swapme in c"}}}
{"dispatch":{"action":"editor_save","params":{"pane":"editor-1","as":"{fixtureRoot}/e2e-portal/swap-c"}}}
{"dispatch":{"action":"editor_close","params":{"pane":"editor-1","path":"{fixtureRoot}/e2e-portal/swap-c"}}}
{"expect":{"pane":"editor-1","field":"tabs[0].path","contains":"/e2e-api/swap-a"}}
{"expect":{"pane":"editor-1","field":"tabs[1]","present":false}}
{"dispatch":{"action":"editor_replace_range","params":{"pane":"editor-1","range":{"start":{"line":1,"column":12},"end":{"line":1,"column":12}},"text":" (dirty)"}}}
{"expect":{"pane":"editor-1","field":"tabs[0].dirty","equals":"true"}}
{"do":{"hotkey":"cmd+shift+f"}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"search"}}
{"do":{"type":{"into":"editor.search.query","text":"swapme"}}}
{"expect":{"pane":"editor-1","field":"search.results[2]","present":true}}
{"do":{"click":"editor.search.replaceToggle"}}
{"expect":{"pane":"editor-1","field":"search.replace","equals":""}}
{"do":{"type":{"into":"editor.search.replace","text":"swapped"}}}
{"expect":{"pane":"editor-1","field":"search.replace","equals":"swapped"}}
{"expect":{"tree":"contains","text":"swapped in b"}}
{"do":{"click":"editor.search.replaceAll"}}
{"expect":{"pane":"editor-1","field":"search.last_replace.replaced","equals":"3"}}
{"expect":{"pane":"editor-1","field":"search.last_replace.files","equals":"3"}}
{"expect":{"pane":"editor-1","field":"search.last_replace.undoable","equals":"true"}}
{"expect":{"tree":"contains","text":"Replaced 3 in 3 files"}}
{"expect":{"pane":"editor-1","field":"search.results","contains":"swapme in a"}}
{"expect":{"pane":"editor-1","field":"search.results[1]","present":false}}
{"expect":{"pane":"editor-1","field":"tabs[0].dirty","equals":"true"}}
{"expect":{"pane":"editor-1","field":"visible_text","contains":"swapped in a (dirty)"}}
{"expect":{"journal":{"contains":"\"action\":\"editor_replace\""}}}
{"dispatch":{"action":"editor_search","params":{"pane":"editor-1","query":"swapped"}}}
{"expect":{"pane":"editor-1","field":"search.results","contains":"swapped in b"}}
{"expect":{"pane":"editor-1","field":"search.results","contains":"swapped in c"}}
{"expect":{"pane":"editor-1","field":"search.results[2]","present":false}}
```

What it proves: the re-run search for `swapme` finds only `swap-a`'s **disk** line (its file untouched);
the buffer holds the replacement (`visible_text`); the two closed files were written (the `swapped`
search). `tree contains "swapped in b"` is the preview's inserted text drawn in the row.

`3b-ii-b-replace-undo.jsonl` — the agent's channel, then Undo after one file changed on disk:
- the same three files, every tab closed but a fresh scratch (so nothing is open);
- dispatch `editor_search {query: "swapme"}`, then `editor_replace {replacement: "swapped"}`; expect
  `search.last_replace.files` equals `3`;
- from a second editor pane, change `swap-b` on disk — 3b-ii's disk-changed precedent:

```jsonl
{"dispatch":{"action":"pane_open","params":{"kind":"editor"}}}
{"expect":{"pane":"editor-2","field":"kind","equals":"editor"}}
{"dispatch":{"action":"editor_open","params":{"pane":"editor-2","path":"{fixtureRoot}/e2e-api/swap-b"}}}
{"dispatch":{"action":"editor_replace_range","params":{"pane":"editor-2","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":1}},"text":"mine "}}}
{"dispatch":{"action":"editor_save","params":{"pane":"editor-2"}}}
{"dispatch":{"action":"pane_close","params":{"id":"editor-2"}}}
```

- click `editor.replace.undo` (`editor_search` already showed `editor-1`'s Search view; a
  `cmd+shift+f` here would hide it);
- expect `search.last_replace.undone` equals `true`, `search.last_replace.restored` equals `2`, and the
  tree contains `changed since the replace — left as it is`;
- dispatch `editor_search {query: "swapme"}`; expect `search.results` contains `swapme in a` and
  `swapme in c`, and `search.results[2]` present false (b stayed replaced);
- `{"dispatch":{"action":"editor_replace_undo","params":{"pane":"editor-1"},"refuses":"no replace to undo"}}`;
- expect the journal contains `"action":"editor_replace_undo"`.

`3b-ii-b-replace-file.jsonl` — Replace in this file, with a regex group:
- `swap-a` and `swap-b` as above, both closed;
- `cmd+shift+f`, click `editor.search.regex`, type `swap(me)` into `editor.search.query`;
- click `editor.search.replaceToggle`, type `X$1` into `editor.search.replace`;
- select `swap-b`'s result without opening it (an open file would be a buffer edit):
  `{"do":{"focus":"editor.search.query"}}`, then `{"do":{"press":"Down"}}` twice — the first ↓ selects
  `swap-a`'s row, the second `swap-b`'s — so the group's button shows;
- click `editor.search.replaceFile:e2e-api/swap-b`;
- expect `search.last_replace.files` equals `1`, and dispatch `editor_search {query: "Xme in b"}` →
  `search.results` contains `Xme in b`, `search.results[1]` present false;
- dispatch `editor_search {query: "swapme in a"}` → `search.results` contains `swapme in a` (a untouched).

`3b-ii-b-replace-cancel.jsonl` (Rule 4), against the `bulk/` haystack. Replace All is pressable only
over results (`editorReplaceAvailable`), so the haystack gains one matching line, sorted last:
`searchBulk()` in `seedgit.go` adds `m["bulk/zz-marker.txt"] = "replace-marker-qz7\n"`. The name and
the line hold no other check's query (`needle`, `line`, `portal`, `zq`, `book`, `.env`; pre-flight F9:
a `needle` line would have matched `3b-ii-search.jsonl`'s `needle` query, safe only because each check
launches alone). `\w+-qz\d` has no literal prefix, so both the search and the replace read all 200 MiB
slowly; `3b-ii-search-cancel`'s `\w+zq\d` does not match the new line (`qz`, not `zq`). The replace
walks `bulk/000.txt` … `bulk/199.txt` before `zz-marker.txt`, in 250 ms calls, so Cancel lands while
it has written nothing:

```jsonl
{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}
{"expect":{"tree":"contains","text":"e2e-git"}}
{"dispatch":{"action":"editor_new_scratch","params":{}}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"1"}}
{"do":{"hotkey":"cmd+shift+f"}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"search"}}
{"do":{"click":"editor.search.regex"}}
{"expect":{"pane":"editor-1","field":"search.regex","equals":"true"}}
{"do":{"type":{"into":"editor.search.query","text":"\\w+-qz\\d"}}}
{"expect":{"pane":"editor-1","field":"search.results[0]","present":true}}
{"do":{"click":"editor.search.replaceToggle"}}
{"do":{"type":{"into":"editor.search.replace","text":"x"}}}
{"expect":{"pane":"editor-1","field":"search.replace","equals":"x"}}
{"do":{"click":"editor.search.replaceAll"}}
{"expect":{"tree":"contains","text":"replacing"}}
{"do":{"click":"editor.replace.cancel"}}
{"expect":{"pane":"editor-1","field":"search.replace_in_flight","equals":"false"}}
{"expect":{"pane":"editor-1","field":"search.last_replace.cancelled","equals":"true"}}
{"expect":{"tree":"contains","text":"Replace cancelled"}}
{"expect":{"journal":{"contains":"\"cancel\":true"}}}
```

`seed_test.go`'s `TestSeedWritesTheSearchHaystackOnlyWhenAsked` changes in three places (pre-flight F9):
the pin `len(strings.Fields(tracked)) != searchBulkFiles` becomes `searchBulkFiles+1`, and the extra file
is asserted by name, committed with the rest:

```go
	if !slices.Contains(strings.Fields(tracked), "bulk/zz-marker.txt") {
		t.Errorf("bulk/zz-marker.txt is not committed: %q", tracked)
	}
	marker, err := os.ReadFile(filepath.Join(api, "bulk", "zz-marker.txt"))
	if err != nil || string(marker) != "replace-marker-qz7\n" {
		t.Errorf("bulk/zz-marker.txt = %q, %v", marker, err)
	}
```

and the query-hygiene loop reads both bodies, `199.txt`'s and the marker's:

```go
	for _, text := range []string{string(body), string(marker)} {
		for _, query := range []string{"needle", "book", "line", "portal", ".env", "zq"} {
			if strings.Contains(strings.ToLower(text), query) {
				t.Errorf("bulk/ matches %q, another check's query", query)
			}
		}
	}
```

(`slices` joins the test file's imports if it is not there). `WantsSearchHaystack` is true for
`3b-ii-b-replace-cancel.jsonl` (its own test).

**Measure one run before committing it** (`make e2e-new` with only this check). If the search has not
finished inside the expect's wait, or the replace finishes before the Cancel press can land, first
make the haystack bigger (more `bulk/` files, each under the 2 MB cap). Only if a measured run still
fails, drop the check and excuse `editor.replace.cancel` and `editor.replace.busy` in
`uncoverable.tsv` on `editor.saving.cancel`'s precedent, citing the measurement; the unit test
`aCancelStopsBetweenBatchesAndKeepsWhatWasWritten` pins the stop between calls, and the walk's row 5
presses it.

`3b-ii-b-reveal.jsonl` — the button and the agent's action, compared on the open folders:

```jsonl
{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}
{"expect":{"tree":"contains","text":"e2e-git"}}
{"dispatch":{"action":"editor_new_scratch","params":{}}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"1"}}
{"dispatch":{"action":"editor_replace_range","params":{"pane":"editor-1","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":1}},"text":"deep"}}}
{"dispatch":{"action":"editor_save","params":{"pane":"editor-1","as":"{fixtureRoot}/e2e-api/deep/er/x.txt"}}}
{"expect":{"pane":"editor-1","field":"tabs[0].path","contains":"/e2e-api/deep/er/x.txt"}}
{"do":{"hotkey":"cmd+b"}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"files"}}
{"expect":{"pane":"editor-1","field":"column.open","equals":"[]"}}
{"parity":{"action":"editor_tree_reveal","params":{"pane":"editor-1"},"click":"editor.tree.reveal","assert":"read_pane"}}
{"expect":{"pane":"editor-1","field":"column.open","contains":"/e2e-api/deep/er"}}
{"expect":{"tree":"contains","text":"x.txt"}}
{"dispatch":{"action":"editor_tree_reveal","params":{"pane":"editor-1","path":"/etc/hosts"},"refuses":"Invariant 6"}}
{"expect":{"journal":{"contains":"\"action\":\"editor_tree_reveal\""}}}
```

The click opens the chain; the dispatch half then opens the same chain again, idempotent, so both
halves read back the same `column.open`.

`3b-ii-b-tab-move.jsonl` — the harness's synthetic drag, then the agent's move back:

```jsonl
{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}
{"expect":{"tree":"contains","text":"e2e-git"}}
{"dispatch":{"action":"editor_new_scratch","params":{}}}
{"dispatch":{"action":"editor_new_scratch","params":{"pane":"editor-1"}}}
{"dispatch":{"action":"editor_new_scratch","params":{"pane":"editor-1"}}}
{"expect":{"pane":"editor-1","field":"tabs[2].scratch","equals":"3"}}
{"expect":{"pane":"editor-1","field":"active","equals":"2"}}
{"do":{"drag":{"from":"editor.tab.0","to":"editor.tab.2"}}}
{"expect":{"pane":"editor-1","field":"tabs[2].scratch","equals":"1"}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"2"}}
{"expect":{"pane":"editor-1","field":"active","equals":"1"}}
{"expect":{"journal":{"contains":"\"action\":\"editor_move_tab\""}}}
{"dispatch":{"action":"editor_move_tab","params":{"pane":"editor-1","from":2,"to":0}}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"1"}}
{"expect":{"pane":"editor-1","field":"active","equals":"2"}}
```

The drag drops over `editor.tab.2`, at whatever point of it the harness's pointer lands (ruling 14,
pre-flight F4: a drop over a tab moves to that tab's index, so no exact centre is needed): Untitled-1 goes last, and
Untitled-3, active, stays active at index 1. **Measure it before committing**: if a measured run shows
the synthetic drag not moving a `DragGesture` tab (the arm was measured on a system drag session,
`api_bind`), excuse the drag in `uncoverable.tsv` with the measurement and keep the dispatch half;
the drag is then the walk's row 7.

`uncoverable.tsv` — one line per item, in the file's existing two-column form, each naming what
covers the rest:
- `editor.tab.middleClick` — the harness posts no middle button (`Do` has no arm for one, and Orca's
  press is an accessibility action); the catcher has no press action. Both halves of what it does are
  covered: `closeEditorTab` by `WindowModelEditorTests.aMiddleClickClosesACleanTabAndAsksAboutADirtyOne`,
  and the walk's row 8 middle-clicks a clean tab and a dirty one.
- `editor_replace` — its parity: the click replaces, and the same dispatch after it finds nothing left
  and answers a different `last_replace`. Both channels are covered, the click by
  `3b-ii-b-replace-all.jsonl` and the dispatch by `3b-ii-b-replace-undo.jsonl`.
- `editor_replace_undo` — its parity: the Undo click spends the undo and the dispatch is then refused
  (`api_undo_fill`'s case). The click is `3b-ii-b-replace-undo.jsonl`'s, and so is the refusal.
- `editor_move_tab` — its parity: the drag moves a tab, and the same `{from, to}` on the moved strip
  moves another. The drag and the dispatch are each `3b-ii-b-tab-move.jsonl`'s.
- `editor.replace.result` — a container, read: `Replaced 3 in 3 files` by `3b-ii-b-replace-all.jsonl`.
- `editor.replace.failure` — a Text, read: `changed since the replace — left as it is` by
  `3b-ii-b-replace-undo.jsonl`.
- `editor.replace.busy` — the tick, a shape with no press action; `3b-ii-b-replace-cancel.jsonl` reads
  its label `replacing` (or, under shape (b), excused with the Cancel).

- [ ] **Step 3: Write the runbook**

`docs/wakil/phase-3b-ii-b-acceptance.md`, in `phase-3b-ii-acceptance.md`'s shape: a header with the
spec and plan links and *"Not yet walked."*; the exit criterion (*replace across the project with
open tabs safe and one undo, reveal the open file, move and middle-click-close tabs — all of it
drivable by the agent*); Decision 39 and design-language §11 named; §0 Setup; §1 The walk; §2–3
Residue; §4 the machine walk, left for `make e2e-runbook`.

§0:

```bash
set -e
ORG=initech   # the org to walk under; initech or umbrella
cd /Users/operator/Desktop/scripts/wakil
rm -rf /tmp/walk-replace /tmp/walk-replace-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-replace/api /tmp/walk-replace/portal /tmp/walk-replace-project
cd /tmp/walk-replace/api && git init -q -b main
printf '.env\n' > .gitignore; echo 'bookingId=walk' > .env
mkdir -p app/Models && echo '<?php $bookingId = 1;' > app/Models/Booking.php
mkdir -p big && for i in $(seq -w 1 200); do yes 'lorem ipsum dolor sit amet' | head -c 1048576 > big/$i.txt; done
echo 'replace-marker-qz7' > big/zz-marker.txt
git add . && $G commit -qm init
cd /tmp/walk-replace/portal && git init -q -b main
mkdir -p src && echo 'const bookingId = 2;' > src/routes.ts
echo 'const bookingId = 3;' > src/a.ts && echo 'const bookingId = 4;' > src/b.ts
git add . && $G commit -qm init
cat > /tmp/walk-replace-project/project.json <<J
{"name":"walk-replace","org":"$ORG","roots":[{"path":"/tmp/walk-replace"}],"scopes":{},"environments":{}}
J
cd /Users/operator/Desktop/scripts/wakil
./bin/wakil project rm walk-replace --org "$ORG" || true
./bin/wakil project add walk-replace --path /tmp/walk-replace-project/project.json --org "$ORG"
```

Then the launch and project-switch paragraph from 3b-ii's §0, with `walk-replace`. `api/.env` is
ignored, so a replace never touches it; `api/big/` (200 MiB) makes a regex replace run for seconds.

§1 The walk:

| # | Do | Expect |
|---|---|---|
| 1 | ⌘T; ⌘P `Booking.php`, type a character in it. ⌘⇧F `bookingId`; press ▸, type `booking_id` (no Enter); then clear the field | The field has the keyboard when it opens. After a pause each result shows `bookingId` struck through and `booking_id` in violet; `.env` is not among them. Cleared, each shows the match struck through only |
| 2 | Type `booking_id` again; press **Replace All** | The tick and Cancel flash; *Replaced 4 in 4 files · Undo replace*. The Search view re-runs and lists only `Booking.php:1` (its file). `Booking.php`'s tab is dirty and reads `booking_id`; ⌘Z there takes it back whole. In a terminal, `cat /tmp/walk-replace/portal/src/*.ts` shows `booking_id` three times and `git -C /tmp/walk-replace/api status --short` shows nothing |
| 3 | In a terminal: `echo '// mine' >> /tmp/walk-replace/portal/src/b.ts`. Press **Undo replace** | *Undid the replace in 2 files*, and `…/b.ts: changed since the replace — left as it is` under it. `cat` shows `routes.ts` and `a.ts` back to `bookingId`, `b.ts` as left. Undo replace is gone |
| 4 | Switch on `.*`; query `const (\w+)`, Replace `let $1`; hover `routes.ts`'s group, press **Replace in this file** | Only `routes.ts` becomes `let bookingId = 2;`; `a.ts` and `b.ts` are untouched. The preview showed `let bookingId` in violet before the press |
| 5 | Query `\w+-qz\d` (still `.*`), Replace `x`; when `zz-marker.txt` is listed, press **Replace All** and then **Cancel** while *replacing* shows | It stops within a moment: *Replace cancelled · replaced …*; anything written is undoable. `git -C /tmp/walk-replace/api status --short` matches what the line says |
| 6 | ⌘B; collapse `walk-replace`; ⌘P `Booking.php`; press the Files header's reveal button. Collapse again; ⌘K *Reveal Active File in Tree*. Then ⌘T and hover the button | The folders open, `Booking.php`'s row is selected and scrolled into view, and typing still goes into the file. ⌘K does the same. With the scratch in front the button is dimmed, its tooltip says there is nothing to reveal, and ⌘K does not offer the command |
| 7 | Open `routes.ts`, `a.ts`, `b.ts`; drag the first tab past the last; drag one up out of the strip and let go; quit (clean) and relaunch | A violet line marks the drop; the tab lands there and the active tab stays active. The drag out of the strip changes nothing. After the relaunch the order is as left |
| 8 | Middle-click a clean tab; type in another and middle-click it | The clean tab closes at once. The dirty one asks *Save changes to …?* with Save / Don't Save / Cancel |
| 9 | Ask the agent "replace bookingId with booking_ref across the project", then "undo that replace" | The same result line and undo as rows 2–3; neither moves the keyboard |

§2 Residue — what the walk cannot establish:
- **The undo is in memory** (Decision 39): a relaunch drops it; nothing keeps it.
- **Only the latest replace undoes**, and buffer edits are ⌘Z's in their tab.
- **The preview covers the 2,000 shown lines**; Replace All replaces past them, which no fixture here
  reaches.
- **Moving a tab between panes** is not part of 3b-ii-b.

§3 Residue — what Cover could not reach, and why (written by the e2e auditor; the starting list):
- **Middle-click** (`editor.tab.middleClick`): no middle button in the harness; row 8.
- **The order after a relaunch** (row 7): one check is one launch; `aMovedOrderComesBackOnRestore`
  pins the saved order.
- **The visual rulings**: strike-through, violet, the drop line, the selected revealed row (row 1, 6, 7).
- **Cancel on a replace**, if the measured run excused it (row 5).
- **The agent in the loop** (row 9).

- [ ] **Step 4: Docs check, the checks green, then red against the base**

Run, as the controller:
1. `make docs-check`, then `make build && make app-test`.
2. `go test ./e2e/...` for the seed change.
3. `make e2e-new`, which writes the proofs. Commit them.
4. A full `make e2e`. It includes the existing `3b-ii-search.jsonl`, which clicks the root header
   `editor.search.group:e2e-api`: it is the regression check for Task 4's change to the group headers'
   accessibility (pre-flight F5) and must stay green.
5. `make e2e-new` again at HEAD.
6. `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-3b-ii-b-acceptance.md`.

Each GUI step needs the operator's go-ahead: the GUI is shared. Never switch checkout while a gate
runs (memory `never-switch-checkout-under-a-gate`).

Expected:
- every 3b-ii-b check is green on the stack and red against the merge-base;
- `wakil-e2e-cover` reports no unexcused new surface and no stale entry;
- the runbook's machine section says green.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-b-5-docs
git add docs e2e
git commit -m "Docs and e2e: Decision 39, design-language §11, the 3b-ii-b checks and acceptance runbook (3b-ii-b PR 5)"
```

---

## Self-review

**Spec coverage.**

| Spec | Task |
|---|---|
| ▸ toggle, Replace field keeps its text, focused on opening | 2 (`editor_search {replace}`), 4 |
| Preview: struck + violet, empty = delete, `$1` / `${name}` / `$$`, one call after 250 ms, 2,000 lines | 1 (`ReplaceTexts`, edits), 2 (`refreshReplacePreview`), 4 (debounce, spans) |
| Replace All, Replace in this file (hover / selected), no confirmation | 2 (`file`), 4 |
| Searches again at the press, every match past 2,000, the search's skips | 1 |
| Open tabs (any pane) edited in the buffer, files untouched; others written atomically | 1 (`skip`, `skipped`), 2 (`replaceInBuffers`) |
| Tick and Cancel, buttons disabled, Cancel between files, written stays | 1 (cursor, ctx), 2 (batches, `cancel`), 4, 5 |
| Result line, re-run search, failures whole | 2 (`editorReplaceSummary`, `runSearch`), 4 |
| Undo: mtime-guarded, changed-since listed, buffers excluded, one, in memory | 2 |
| Reveal: button, ⌘K command, opens folders, selects and scrolls, keyboard stays, disabled + tooltip, never automatic | 3, 4 |
| Tab drag, violet line, active kept, persisted, outside / own place no-op, one pane | 3 (pure rules, action), 4 |
| Middle-click → ⌘W's path, dirty prompts | 3 (`closeEditorTab`), 4 |
| Four actions, prices, kinds; `read_pane`'s three keys | 2, 3 |
| Errors and edges table (Rules 1–9, stale search, other pane, read-only file, skips, same text, typing, org switch) | 1, 2, 3 |
| Testing (Go, WakilKit, e2e, walk) | 1–5 |
| Charter: Decision 39, design-language §11, 3b-ii roadmap row, no invariant change | 5 |

**Rulings**, recorded once above: 1 (cursor, not call cancellation), 2 (`cancel` param), 3 (`editor_search
{replace}`), 4 (`edits`), 5 (`skipped`), 6 (`only` filters the walk), 7 (`access(W_OK)`), 8 (line by
line), 9 (empty query), 10 (undo in the pane's snapshot), 11 (`undone` / `restored` / `cancelled`),
12 (⌘K, hidden), 13 (no-tab errors), 14 (`DragGesture`, drop after a middle), 15 (relaunch order is
the walk's).

**Type consistency.** These names are used identically across Tasks 2–4: `EditorReplaceState`,
`EditorReplaceResult`, `EditorReplaceUndoRecord`, `EditorReplaceFailure`, `EditorReplaceEdit`,
`EditorReplaceSpan`, `editorReplaceAvailable`, `editorReplaceSummary`, `editorReplacePreviewSpans`,
`editorMovingTab`, `editorTabDropTarget`, `EditorTabDrop`, `editorTabDropX`,
`EditorTreeRevealRequest`, `revealActiveFileInTree`, `editorTreeRevealTaken`, `closeEditorTab`,
`editorActiveIsFile`. Go's JSON keys (`files`, `failures`, `skipped`, `next`, `results`, `edits`,
`start`, `end`) are the ones `editorReplaceBatch(from:)` and `editorReplacedTexts(from:)` read, and
the ones FakeFiles answers.
