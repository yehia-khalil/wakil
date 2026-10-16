# 3b-ii: the editor's left column — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every editor pane gets a left column with two views — **Files** (⌘B), a multi-root tree
that lists ignored files dimmed and loads heavy folders on demand, opening into a preview tab — and
**Search** (⌘⇧F) across files; ⌘F finds in the open file with Monaco's own bar; the agent drives all
of it through six actions.

**Architecture:**
- **Go reads.** `wakil-files` gains three things, all read-only and confined to the roots:
  `ignored`, `heavy` and `repos` on `files_list`, and the new tools `files_list_dir` and
  `files_search`.
- **WakilKit decides.** It gets pure models:
  - the tree rows, keys and selection fallback;
  - search grouping and find matches;
  - the preview-tab rule.
- **The column's state is the pane's.** It lives in `EditorSnapshot.column` and persists on
  `Pane.editorColumn`.
- **One file list per root.** An `EditorFileLists` actor holds it and is the `ToolCaller` that ⌘P's
  `FilesSource` and the editor actions both read. The existing editor `RootWatcher` invalidates it.
- **WakilApp draws.** It draws the column in SwiftUI and bridges Monaco's find widget.

**Tech Stack:**
- Go 1.x with `modelcontextprotocol/go-sdk` (fork).
- Swift 6.4 in language mode 6, Swift Testing, Observation, SwiftUI and WebKit.
- Monaco 0.52.2, bundled under `app/Sources/WakilApp/monaco/`.

**Spec:** `docs/superpowers/specs/2026-10-13-3b-ii-editor-tree-design.md` (read it with this plan; it is
the authority).

## Global Constraints

These are copied from the spec; every task's requirements include them.

**Listing and search limits**
- The 50,000 cap now counts `files` and `ignored` together, and `truncated` still says when it was
  hit. A tracked file is never dropped while an ignored one is kept: tracked files are taken first.
- The heavy names are a fixed list: `vendor`, `node_modules`, `.git`.
- Search stops at 2,000 matches, sets `truncated`, and stops when the call's context is cancelled.
  The note reads *"only the first 2,000 matches are shown"*.
- Search skips gitignored files and the heavy folders.
- A truncated root shows *"only the first 50,000 files are listed"* at its top, as ⌘P does.
- `preview` is the matching line, trimmed to 400 characters around the match.

**The column**
- The column starts at 240 pt and can go from 160 pt up to half the pane's width.
- Nothing hides the column automatically, at any width. It shows or hides only through ⌘B, ⌘⇧F, the
  toggle at the top of the column, or the agent.
- What each pane remembers across a relaunch:
  - whether the column is showing;
  - which view;
  - its width;
  - which nodes are open.
- A new pane takes the column state you last left any editor pane in.

**Search and find**
- The query line arrives focused (Rule 3) and searches as you type, after a 250 ms pause (Rule 2).
  Enter runs it at once.
- Find in file uses Monaco's own find bar, recoloured with Wakil's tokens: ⌘F, ⌘G and ⇧⌘G, and ⌥⌘F
  to replace.

**Tree and preview tab**
- A click or Return opens a file in the pane's one *preview tab*, whose title is in italics. The
  next file opened that way replaces it.
- The preview tab is kept as an ordinary tab on:
  - an operator edit;
  - an agent edit;
  - a double-click on the row;
  - a double-click on the tab.
- The tree is read-only: no new file, folder, rename, move or delete (3b-iv).

**Refusals, actions and invariants**
- The only refusals are paths outside the roots. They name *Invariant 6* and *Decision 36*, in
  `outsideRoots`' words.
- Every write goes through the one dispatch path (Invariant 2). The `editor_*` actions are
  `.control`; `files_search` is `.read`. All are `.agentReachable`.

**Process**
- Commits carry no `Co-Authored-By` or "Generated with Claude Code" lines (operator rule).
- Stacked PRs with gh-stack, one task per layer, on top of `yehia-khalil/3b-ii-spec`. Branches are
  `yehia-khalil/3b-ii-<n>-<slug>`.

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
- Layering, from `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`, which is shrink-only:
  - `Layout` must not use `Editor`.
  - `Command` must not use `Editor`.
  - No task adds a link to that file.

## Review Focus

Five inputs the spec implies and no spec-level test exercises, most likely first.

1. **A repository whose ignored build output is huge** (e.g. 60,000 files under an ignored
   `storage/`). Every tracked file must still be listed, ignored files fill only what is left of
   the cap, and `truncated` is true. Pinned in Task 1 by
   `TestFilesListIgnoredFillsOnlyWhatTrackedLeaves`.
2. **The operator types a second query while the first search is still running.** The first
   result must never land over the second. Pinned in Task 6 by
   `aSupersededSearchNeverOverwritesTheNewerResults`.
3. **A file with multi-byte characters before a match** (Arabic or emoji on the line). Columns are
   UTF-16, as Monaco counts them, in both Go search and Swift find. Pinned in Task 2 by
   `TestFilesSearchColumnsAreUTF16`, and in Task 4 by `findColumnsAreUTF16`.
4. **The preview tab is dirty when the next file is opened as a preview.** The dirty tab must be
   kept, never replaced; the edit itself un-previews it. The agent editing a preview tab also keeps
   it. Pinned in Task 5 by `aPreviewOpenNeverReplacesADirtyTab` and
   `anAgentEditKeepsThePreviewTab`.
5. **A restored column whose open folders were deleted, or whose root left the project.** Missing
   paths are dropped quietly, and the column still shows. Pinned in Task 3 by
   `pruneDropsOpenPathsThatNoLongerExist`.

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `internal/wakilcore/files.go`, `files_test.go` | 1, 2 | `ignored` / `heavy` / `repos`, `ListDir`, `SearchFiles` |
| `cmd/wakil-files/main.go`, `main_test.go`, `schema_test.go` | 1, 2 | `files_list_dir`, `files_search` tools |
| `docs/architecture/go.md` | 1, 2 | `### wakil-files` tool list |
| `app/Sources/WakilKit/Layout/Pane.swift`, `Layout/LayoutStore.swift` | 3 | `EditorColumnState`, `Pane.editorColumn`, `LayoutSnapshot.editorColumnDefault`, `setEditorColumn` |
| `app/Sources/WakilKit/Editor/EditorTree.swift` (new) | 3 | listings → rows, keys, selection fallback, width clamp, prune |
| `app/Sources/WakilKit/Editor/EditorSearch.swift` (new) | 4 | search state and grouping, find matcher, debounce |
| `app/Sources/WakilKit/Editor/EditorSnapshot.swift`, `EditorPaneKind.swift`, `PaneStore+Editor.swift`, `EditorRenderer.swift` | 4, 6 | column, search and find fields, `tabs[].preview`, `read_pane`, the find render step |
| `app/Sources/WakilKit/Editor/EditorFileLists.swift` (new) | 5 | the shared per-root list, heavy folders, watched/unwatched |
| `app/Sources/WakilKit/Editor/EditorActions.swift` | 5, 6 | `editor_tree*`, preview in `editor_open`, restore, `editor_find`, `editor_search`, `files_search` |
| `app/Sources/WakilKit/Command/PaletteEntry.swift`, `PaletteSources.swift`, `PaletteSearch.swift` | 7 | ignored rows, dimmed, ranked last |
| `app/Sources/WakilKit/App/AppWiring.swift`, `App/WindowModel.swift`, `app/Sources/WakilApp/WindowSession.swift` | 7 | wiring, watcher invalidation, ⌘B / ⌘⇧F entry points, listings mirror, find reports |
| `app/Sources/WakilApp/EditorColumn.swift` (new), `EditorPane.swift`, `Canvas.swift`, `AppScene.swift`, `MonacoEditorRenderer.swift`, `monaco-host.html`, `Palettes.swift` | 8 (6: a no-op `find` in `MonacoEditorRenderer`) | drawing, menu, Monaco find |
| `e2e/driver/seedgit.go`, `e2e/checks/seeded/3b-ii-*.jsonl`, `e2e/checks/uncoverable.tsv`, docs | 9 | checks, runbook, charter |

Test files are:
- `internal/wakilcore/files_test.go`;
- `cmd/wakil-files/main_test.go`;
- `app/Tests/WakilKitTests/`: `EditorTreeTests.swift` (new), `EditorSearchTests.swift` (new),
  `EditorTreeActionsTests.swift` (new), `EditorSearchActionsTests.swift` (new), and the existing
  `EditorTestSupport.swift` (FakeFiles), `PaletteFilesSourceTests.swift`, `LayoutStoreTests.swift`
  and `WindowModelEditorTests.swift`.

---

### Task 1: `files_list` learns ignored, heavy and repos; `files_list_dir` (PR 1)

**Files:**
- Modify: `internal/wakilcore/files.go`, `internal/wakilcore/files_test.go`
- Modify: `cmd/wakil-files/main.go`, `cmd/wakil-files/main_test.go`, `cmd/wakil-files/schema_test.go`
- Modify: `docs/architecture/go.md` (the `### wakil-files` section)

**Interfaces:**
- Consumes: `ListFiles`, `gitListFiles`, `walkFiles`, `ConfineFilePath`, `realRoots`, `outsideRoots`,
  `skippedDirs`, `gitSafetyArgs` (all in `internal/wakilcore`).
- Produces (Go):
  - `HeavyDirs = []string{".git", "node_modules", "vendor"}`
  - `FileList{Root string; Files, Ignored, Heavy, Repos []string; Truncated bool}`, with JSON keys `root`,
    `files`, `ignored`, `heavy`, `repos` and `truncated`. Every slice is non-nil.
  - `DirEntry{Name string json:"name"; Kind string json:"kind"}`, where `Kind` is `"file"` or
    `"dir"`.
  - `DirList{Root, Dir string; Entries []DirEntry}`
  - `ListDir(root, dir string, roots []string) (DirList, error)`
- Produces (MCP):
  - `files_list {root}` → `{root, files, ignored, heavy, repos, truncated}`.
  - `files_list_dir {root, dir}` → `{root, dir, entries: [{name, kind}]}`.
  - `dir` is relative to `root`, slash-separated.

**Ruling recorded here (spec gap):**
- **`repos` is added to `files_list`.** The spec says a child repository shows as its own node, but
  nothing in `files_list` says which folders are repositories. The walk already knows, so it
  reports them as `repos`: relative paths, sorted.
- **Outside a repository, every `skippedDirs` name is also `heavy`.** The spec's heavy list is the
  three names, and the walk's own rule already skips `.venv`, `DerivedData` and the rest. Listing
  their files as "ignored" would spend the cap on a virtualenv. So they become heavy stubs as well,
  and `vendor` joins the walk's skip.
  - Inside a repository the heavy list is exactly the spec's three names.
  - The spec's `git ls-files --exclude=<heavy>` is wrong: `--exclude` adds an ignore pattern. The
    plan uses pathspec excludes instead (`:(exclude,glob)**/vendor/**`), measured on git 2.x with
    the shape below.

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/files_test.go`:

```go
func TestFilesListInARepoReportsIgnoredAndHeavySeparately(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), ".env\nvendor/\nstorage/\nnode_modules/\n")
	write(t, filepath.Join(a, "app.php"), "a")
	write(t, filepath.Join(a, ".env"), "DB=1")
	write(t, filepath.Join(a, "storage", "l.log"), "l")
	write(t, filepath.Join(a, "vendor", "autoload.php"), "v")
	write(t, filepath.Join(a, "web", "node_modules", "x", "i.js"), "x")
	l, err := ListFiles(context.Background(), a, []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Files, ","); got != ".gitignore,app.php" {
		t.Fatalf("files %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != ".env,storage/l.log" {
		t.Fatalf("ignored %v", got)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,vendor,web/node_modules" {
		t.Fatalf("heavy %v", got)
	}
	if len(l.Repos) != 0 || l.Truncated {
		t.Fatalf("repos %v truncated %v", l.Repos, l.Truncated)
	}
}

func TestFilesListAFolderOfReposReportsReposAndTheirIgnored(t *testing.T) {
	a, _, _ := filesRoots(t)
	api := filepath.Join(a, "api")
	if err := os.MkdirAll(api, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, api)
	write(t, filepath.Join(api, ".gitignore"), ".env\nvendor/\n")
	write(t, filepath.Join(api, "main.go"), "m")
	write(t, filepath.Join(api, ".env"), "S=1")
	write(t, filepath.Join(api, "vendor", "a.php"), "v")
	write(t, filepath.Join(a, "notes.md"), "n")
	write(t, filepath.Join(a, ".venv", "bin", "python"), "p")
	l, err := ListFiles(context.Background(), a, []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Files, ","); got != "api/.gitignore,api/main.go,notes.md" {
		t.Fatalf("files %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "api/.env" {
		t.Fatalf("ignored %v", got)
	}
	if got := strings.Join(l.Heavy, ","); got != ".venv,api/.git,api/vendor" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Repos, ","); got != "api" {
		t.Fatalf("repos %v", got)
	}
}

// Review Focus 1: tracked files are taken first; ignored files fill only what is left.
func TestFilesListIgnoredFillsOnlyWhatTrackedLeaves(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "storage/\n")
	for i := 0; i < 10; i++ {
		write(t, filepath.Join(a, fmt.Sprintf("t%02d.go", i)), "t")
	}
	d := filepath.Join(a, "storage")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < FileListCap; i++ {
		if err := os.WriteFile(filepath.Join(d, fmt.Sprintf("%05d.log", i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	l, err := ListFiles(context.Background(), a, []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if len(l.Files) != 11 || len(l.Files)+len(l.Ignored) != FileListCap || !l.Truncated {
		t.Fatalf("files %d ignored %d truncated %v", len(l.Files), len(l.Ignored), l.Truncated)
	}
}

// Tracked first, across repositories: in a folder of repositories, an early repository's ignored
// files never stop the walk before a later repository's tracked files are listed.
func TestFilesListAnEarlyReposIgnoredNeverCrowdsOutALaterReposTracked(t *testing.T) {
	a, _, _ := filesRoots(t)
	first, second := filepath.Join(a, "aa"), filepath.Join(a, "bb")
	for _, d := range []string{filepath.Join(first, "storage"), second} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitInit(t, first)
	gitInit(t, second)
	write(t, filepath.Join(first, ".gitignore"), "storage/\n")
	for i := 0; i < FileListCap+1; i++ {
		if err := os.WriteFile(filepath.Join(first, "storage", fmt.Sprintf("%05d.log", i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(t, filepath.Join(second, "main.go"), "m")
	l, err := ListFiles(context.Background(), a, []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(l.Files, "bb/main.go") || len(l.Files)+len(l.Ignored) != FileListCap || !l.Truncated {
		t.Fatalf("files %v ignored %d truncated %v", l.Files, len(l.Ignored), l.Truncated)
	}
}

func TestFilesListDirListsOneFolderSortedFoldersFirst(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "vendor", "b.php"), "b")
	write(t, filepath.Join(a, "vendor", "a.php"), "a")
	write(t, filepath.Join(a, "vendor", "laravel", "x.php"), "x")
	d, err := ListDir(a, "vendor", []string{a})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range d.Entries {
		got = append(got, e.Kind+":"+e.Name)
	}
	if strings.Join(got, ",") != "dir:laravel,file:a.php,file:b.php" {
		t.Fatalf("got %v", got)
	}
}

func TestFilesListDirRefusesAFolderOutsideTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	if err := os.Symlink(outside, filepath.Join(a, "link")); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{"../out", "link"} {
		_, err := ListDir(a, dir, []string{a})
		if err == nil || !strings.Contains(err.Error(), "Invariant 6") || !strings.Contains(err.Error(), "Decision 36") {
			t.Fatalf("%s: got %v", dir, err)
		}
	}
}
```

Add `"fmt"` and `"slices"` to the test file's imports.

Append to `cmd/wakil-files/main_test.go`, beside the existing round-trip test, which calls
`files_list` through `callFiles`. The project root comes from the file's own `setupProject(t,
environmentsJSON, envName)` helper, which makes a one-root project active and returns its
directory, symlink-resolved:

```go
func TestFilesListDirIsServed(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	if err := os.MkdirAll(filepath.Join(pdir, "vendor", "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	_, out := callFiles(t, "files_list_dir", map[string]any{"root": pdir, "dir": "vendor"})
	entries, _ := out["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("got %v", out)
	}
}
```

`schema_test.go` gets the new name:

```go
mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{"files_list", "files_list_dir", "files_read", "files_write"})
```

- [ ] **Step 2: Run them; they fail**

Run: `go test ./internal/wakilcore/ -run 'TestFilesList' && go test ./cmd/wakil-files/`
Expected: FAIL — `l.Ignored undefined`, `undefined: ListDir`, unknown tool `files_list_dir`.

- [ ] **Step 3: Implement**

In `internal/wakilcore/files.go`:

```go
// FileList is one root's files, relative and slash-separated, sorted. Ignored are the gitignored
// files outside the heavy folders; Heavy the heavy folders found, never walked; Repos the child
// repositories of a folder of repositories (3b-ii).
type FileList struct {
	Root      string   `json:"root"`
	Files     []string `json:"files"`
	Ignored   []string `json:"ignored"`
	Heavy     []string `json:"heavy"`
	Repos     []string `json:"repos"`
	Truncated bool     `json:"truncated"`
}

// HeavyDirs are listed as one entry each and never walked: their contents load only when the
// operator opens one (files_list_dir, 3b-ii). Outside a repository every skippedDirs name is
// heavy too — there are no ignore rules to keep a virtualenv out of the list.
var HeavyDirs = []string{".git", "node_modules", "vendor"}

func isHeavyName(name string) bool {
	for _, h := range HeavyDirs {
		if h == name {
			return true
		}
	}
	return false
}

// DirEntry is one entry of a folder files_list_dir read.
type DirEntry struct {
	Name string `json:"name"`
	Kind string `json:"kind"` // "file" or "dir"
}

// DirList is one folder's direct entries, folders first, each sorted by name.
type DirList struct {
	Root    string     `json:"root"`
	Dir     string     `json:"dir"`
	Entries []DirEntry `json:"entries"`
}

// gitLines runs git in dir and splits its -z output.
func gitLines(ctx context.Context, dir string, args ...string) ([]string, error) {
	cmd := exec.CommandContext(ctx, "git", append(append([]string{}, gitSafetyArgs...), args...)...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var lines []string
	for _, f := range bytes.Split(out, []byte{0}) {
		if len(f) > 0 {
			lines = append(lines, string(f))
		}
	}
	return lines, nil
}

// gitListFiles answers git's view of the repository at dir: tracked plus untracked, ignores
// applied, relative to dir. Its exec-and-split body is now gitLines'.
func gitListFiles(ctx context.Context, dir string) ([]string, error) {
	return gitLines(ctx, dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
}

// gitListIgnored answers the ignored files of the repository at dir, outside the heavy folders.
// Pathspec excludes, not --exclude: --exclude would ADD an ignore pattern (measured).
func gitListIgnored(ctx context.Context, dir string) ([]string, error) {
	args := []string{"ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", "."}
	for _, h := range HeavyDirs {
		args = append(args, ":(exclude,glob)**/"+h+"/**")
	}
	return gitLines(ctx, dir, args...)
}

// gitListHeavy answers the repository's ignored heavy folders, plus its own .git. `--directory`
// collapses an ignored folder to one "name/" entry; the base name decides heaviness (a pathspec
// does not filter --directory output reliably — measured: `storage/` came back for `**/vendor`).
func gitListHeavy(ctx context.Context, dir string) ([]string, error) {
	lines, err := gitLines(ctx, dir, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
	if err != nil {
		return nil, err
	}
	heavy := []string{".git"}
	for _, l := range lines {
		if strings.HasSuffix(l, "/") {
			d := strings.TrimSuffix(l, "/")
			if isHeavyName(filepath.Base(d)) {
				heavy = append(heavy, d)
			}
		}
	}
	return heavy, nil
}
```

Replace the existing `gitListFiles` (files.go:129–146) with the one-line version above, so the
exec-and-split body lives only in `gitLines`.

Rework `walkFiles` so it also returns ignored, heavy and repos. **Only tracked files stop the
walk.** Ignored files are kept up to `FileListCap+1` while appending and never stop it: if they
did, an early child repository's ignored build output would end the walk before a later
repository's tracked files were listed, breaking "tracked files are taken first". The `+1` lets
`ListFiles` still see the overflow and set `truncated`. Its signature becomes:

```go
type walked struct{ files, ignored, heavy, repos []string }

func walkFiles(ctx context.Context, real string) (walked, error) {
	var w walked
	full := func() bool { return len(w.files) > FileListCap }
	addIgnored := func(f string) {
		if len(w.ignored) <= FileListCap {
			w.ignored = append(w.ignored, f)
		}
	}
	err := filepath.WalkDir(real, func(p string, d fs.DirEntry, e error) error {
		if cerr := ctx.Err(); cerr != nil {
			return cerr
		}
		if e != nil {
			if d != nil && d.IsDir() && p != real {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(real, p)
		rel = filepath.ToSlash(rel)
		if !d.IsDir() {
			w.files = append(w.files, rel)
			if full() {
				return errListFull
			}
			return nil
		}
		if p == real {
			return nil
		}
		if skippedDirs[d.Name()] || isHeavyName(d.Name()) {
			w.heavy = append(w.heavy, rel)
			return filepath.SkipDir
		}
		if _, serr := os.Lstat(filepath.Join(p, ".git")); serr == nil {
			if sub, gerr := gitListFiles(ctx, p); gerr == nil {
				w.repos = append(w.repos, rel)
				prefix := rel + "/"
				for _, f := range sub {
					w.files = append(w.files, prefix+f)
				}
				if ig, ierr := gitListIgnored(ctx, p); ierr == nil {
					for _, f := range ig {
						addIgnored(prefix + f)
					}
				}
				if hv, herr := gitListHeavy(ctx, p); herr == nil {
					for _, h := range hv {
						w.heavy = append(w.heavy, prefix+h)
					}
				}
				if full() {
					return errListFull
				}
				return filepath.SkipDir
			}
		}
		return nil
	})
	if errors.Is(err, errListFull) {
		err = nil
	}
	return w, err
}
```

Add `"vendor": true` to `skippedDirs`. Then replace `ListFiles`' body after the root check:

```go
	var w walked
	if files, gerr := gitListFiles(ctx, real); gerr == nil {
		w.files = files
		if w.ignored, err = gitListIgnored(ctx, real); err != nil {
			return FileList{}, err
		}
		if w.heavy, err = gitListHeavy(ctx, real); err != nil {
			return FileList{}, err
		}
	} else {
		if cerr := ctx.Err(); cerr != nil {
			return FileList{}, cerr
		}
		if w, err = walkFiles(ctx, real); err != nil {
			return FileList{}, err
		}
	}
	for _, s := range []*[]string{&w.files, &w.ignored, &w.heavy, &w.repos} {
		sort.Strings(*s)
		if *s == nil {
			*s = []string{}
		}
	}
	// Tracked first (spec): ignored files fill only what the tracked ones leave of the cap.
	truncated := false
	if len(w.files) > FileListCap {
		w.files, truncated = w.files[:FileListCap], true
	}
	if room := FileListCap - len(w.files); len(w.ignored) > room {
		w.ignored, truncated = w.ignored[:room], true
	}
	return FileList{Root: real, Files: w.files, Ignored: w.ignored, Heavy: w.heavy, Repos: w.repos, Truncated: truncated}, nil
```

Add `ListDir`:

```go
// ListDir lists one folder of a root: its direct entries, folders first, each sorted. dir is
// relative to root; it is resolved through symlinks and refused outside the roots (Invariant 6,
// Decision 36).
func ListDir(root, dir string, roots []string) (DirList, error) {
	real, _, err := ConfineFilePath(filepath.Join(root, filepath.FromSlash(dir)), roots, true)
	if err != nil {
		return DirList{}, err
	}
	ents, err := os.ReadDir(real)
	if err != nil {
		return DirList{}, UserError(dir + " is not readable: " + err.Error())
	}
	var dirs, files []DirEntry
	for _, e := range ents {
		if e.IsDir() {
			dirs = append(dirs, DirEntry{Name: e.Name(), Kind: "dir"})
		} else {
			files = append(files, DirEntry{Name: e.Name(), Kind: "file"})
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return dirs[i].Name < dirs[j].Name })
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	out := append(dirs, files...)
	if out == nil {
		out = []DirEntry{}
	}
	return DirList{Root: root, Dir: dir, Entries: out}, nil
}
```

`ConfineFilePath` with `mustExist: true` refuses both `../out` and a link to `outside` through
`outsideRoots`. That is the refusal the test reads.

In `cmd/wakil-files/main.go`:

```go
type listDirArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Dir  string `json:"dir" jsonschema:"a folder inside root, relative and slash-separated"`
}
```

```go
	mcp.AddTool(s, &mcp.Tool{Name: "files_list_dir", Description: "Read-only. One folder's direct entries ({name, kind: file|dir}), folders first, each sorted — how a heavy folder (vendor, node_modules, .git) opens. dir is relative to root. Confined to the active project's roots (Invariant 6, Decision 36)."},
		func(_ context.Context, _ *mcp.CallToolRequest, a listDirArg) (*mcp.CallToolResult, wakilcore.DirList, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.DirList{}, nil
			}
			d, err := wakilcore.ListDir(a.Root, a.Dir, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.DirList{}, nil
			}
			return nil, d, nil
		})
```

Update `files_list`'s description to: `"Read-only. One root's files, relative and sorted: in a
repository git's tracked and untracked files (files), its gitignored files outside the heavy
folders (ignored), and the heavy folders vendor, node_modules and .git (heavy, never walked);
otherwise a walk that lists each child repository the same way (repos) and reports the walk's
skipped folders as heavy. files and ignored together are capped at 50,000, tracked first;
truncated says so."`

In `docs/architecture/go.md`, under `### wakil-files`, list the four tools with one line each, in
the section's existing style.

- [ ] **Step 4: Run them; they pass, with the old tests**

Run: `go test ./internal/wakilcore/ -run 'TestFiles' && go test ./cmd/wakil-files/`
Expected: PASS. The existing `TestFilesListAFolderOfReposListsEachRepoThroughGit`,
`TestFilesListOutsideARepoSkipsHeavyFolders` and `TestFilesListWalkStopsAtTheCapAndSaysTruncated`
still pass, because `Files` and the walk's stop on tracked files are unchanged for them.

- [ ] **Step 5: Commit on the new layer**

```bash
gh stack add yehia-khalil/3b-ii-1-files-list
git add internal/wakilcore/files.go internal/wakilcore/files_test.go cmd/wakil-files docs/architecture/go.md
git commit -m "wakil-files: files_list reports ignored files, heavy folders and child repositories; files_list_dir opens one folder (3b-ii PR 1)"
```

---

### Task 2: `files_search` (PR 2)

**Files:**
- Modify: `internal/wakilcore/files.go`, `internal/wakilcore/files_test.go`
- Modify: `cmd/wakil-files/main.go`, `cmd/wakil-files/main_test.go`, `cmd/wakil-files/schema_test.go`, `docs/architecture/go.md`

**Interfaces:**
- Consumes: `ListFiles` (Task 1), `realRoots`, `FileCap`.
- Produces (Go):
  - `SearchCap = 2000`
  - `SearchQuery{Query string; Case, Word, Regex bool}`
  - `SearchMatch{Root, Path string; Line, Column int; Preview string}`, with JSON keys `root`,
    `path`, `line`, `column` and `preview`. `Root` is the root **as the caller passed it** (an
    entry of `only`, else of `roots`), never its symlink-resolved path, so it equals the Swift
    side's root strings. `Path` is relative to `Root`. `Line` and `Column` are 1-based, and
    `Column` counts UTF-16 units.
  - `SearchResult{Matches []SearchMatch; Truncated bool}`
  - `SearchFiles(ctx context.Context, roots []string, only []string, q SearchQuery) (SearchResult, error)`
- Produces (MCP): `files_search {roots?, query, case?, word?, regex?}` →
  `{matches: [...], truncated}`. When `roots` is empty it searches every root of the project.

**Ruling recorded here (spec deviation):**
- The spec says `git grep` inside repositories and a walk elsewhere. **The plan searches both with
  Go's `regexp` over `ListFiles`' `files`.**
- Why:
  - `git grep -E` is POSIX ERE, so a pattern Go accepts (`\d`) would fail inside a repository and
    work outside one.
  - git's error text is not Go's: measured, `fatal: command line, 'book(': parentheses not
    balanced`. The spec requires Go's own text for an invalid regex.
- Searching what `ListFiles` lists already gives "skips gitignored files and the heavy folders".
  `--untracked` is what `ListFiles`' `--others` already includes.

- [ ] **Step 1: Write the failing tests**

```go
func searchFixture(t *testing.T) (a, b string) {
	t.Helper()
	a, b, _ = filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), ".env\n")
	write(t, filepath.Join(a, "Booking.php"), "class Booking {\n  $bookingId = 1;\n  $BOOKINGID = 2;\n}\n")
	write(t, filepath.Join(a, ".env"), "bookingId=secret\n")
	write(t, filepath.Join(b, "routes.ts"), "const bookingIdx = 3;\n")
	return a, b
}

func TestFilesSearchFindsAcrossRootsAndSkipsIgnored(t *testing.T) {
	a, b := searchFixture(t)
	r, err := SearchFiles(context.Background(), []string{a, b}, nil, SearchQuery{Query: "bookingId"})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, m := range r.Matches {
		got = append(got, fmt.Sprintf("%s:%d:%d", filepath.Base(m.Root)+"/"+m.Path, m.Line, m.Column))
	}
	if strings.Join(got, ",") != "a/Booking.php:2:4,a/Booking.php:3:4,b/routes.ts:1:7" || r.Truncated {
		t.Fatalf("got %v", got)
	}
}

func TestFilesSearchSwitches(t *testing.T) {
	a, b := searchFixture(t)
	cases := []struct {
		q    SearchQuery
		want int
	}{
		{SearchQuery{Query: "bookingId", Case: true}, 2},           // Booking.php line 2, routes.ts
		{SearchQuery{Query: "bookingId", Word: true}, 2},           // not bookingIdx
		{SearchQuery{Query: "book\\w+Id\\b", Regex: true, Case: true}, 1},
		{SearchQuery{Query: "booking(", Regex: false}, 0},          // literal: no error
	}
	for _, c := range cases {
		r, err := SearchFiles(context.Background(), []string{a, b}, nil, c.q)
		if err != nil || len(r.Matches) != c.want {
			t.Fatalf("%+v: %d matches, err %v", c.q, len(r.Matches), err)
		}
	}
}

func TestFilesSearchAnInvalidRegexIsGosOwnError(t *testing.T) {
	a, b := searchFixture(t)
	_, err := SearchFiles(context.Background(), []string{a, b}, nil, SearchQuery{Query: "book(", Regex: true})
	if err == nil || !strings.Contains(err.Error(), "missing closing )") {
		t.Fatalf("got %v", err)
	}
}

func TestFilesSearchStopsAtTheCap(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "many.txt"), strings.Repeat("x\n", SearchCap+5))
	r, err := SearchFiles(context.Background(), []string{a}, nil, SearchQuery{Query: "x"})
	if err != nil || len(r.Matches) != SearchCap || !r.Truncated {
		t.Fatalf("%d matches, truncated %v, err %v", len(r.Matches), r.Truncated, err)
	}
}

func TestFilesSearchHonoursACancelledContext(t *testing.T) {
	a, b := searchFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := SearchFiles(ctx, []string{a, b}, nil, SearchQuery{Query: "b"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestFilesSearchSkipsBinaryAndOverCapFiles(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "bin.dat"), "needle\x00")
	write(t, filepath.Join(a, "big.txt"), "needle\n"+strings.Repeat("y", FileCap))
	write(t, filepath.Join(a, "ok.txt"), "needle\n")
	r, _ := SearchFiles(context.Background(), []string{a}, nil, SearchQuery{Query: "needle"})
	if len(r.Matches) != 1 || r.Matches[0].Path != "ok.txt" {
		t.Fatalf("got %+v", r.Matches)
	}
}

// Review Focus 3: columns are UTF-16 units, as Monaco counts them.
func TestFilesSearchColumnsAreUTF16(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "ar.txt"), "حجز 😀 bookingId\n")
	r, _ := SearchFiles(context.Background(), []string{a}, nil, SearchQuery{Query: "bookingId"})
	// "حجز " is 4 UTF-16 units, "😀 " is 3 (a surrogate pair and a space): the match starts at 8.
	if len(r.Matches) != 1 || r.Matches[0].Column != 8 {
		t.Fatalf("got %+v", r.Matches)
	}
}

func TestFilesSearchPreviewIsTrimmedAroundTheMatch(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "long.txt"), strings.Repeat("a", 1000)+"needle"+strings.Repeat("b", 1000)+"\n")
	r, _ := SearchFiles(context.Background(), []string{a}, nil, SearchQuery{Query: "needle"})
	if len(r.Matches) != 1 || len([]rune(r.Matches[0].Preview)) > 400 || !strings.Contains(r.Matches[0].Preview, "needle") {
		t.Fatalf("got %q", r.Matches[0].Preview)
	}
}

func TestFilesSearchRefusesARootThatIsNotTheProjects(t *testing.T) {
	a, b := searchFixture(t)
	_, err := SearchFiles(context.Background(), []string{a}, []string{b}, SearchQuery{Query: "x"})
	if err == nil || !strings.Contains(err.Error(), "Invariant 6") {
		t.Fatalf("got %v", err)
	}
}

// A match names its root as the caller passed it, never its real path: Swift's roots, the editor
// watcher and editor_refresh {root} all use the project's path (/tmp/…, not /private/tmp/…), and
// "changed since this search" compares against them.
func TestFilesSearchNamesTheRootAsPassedNotItsRealPath(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "n.txt"), "needle\n")
	link := filepath.Join(filepath.Dir(a), "link-a")
	if err := os.Symlink(a, link); err != nil {
		t.Fatal(err)
	}
	for _, only := range [][]string{nil, {link}} {
		r, err := SearchFiles(context.Background(), []string{link}, only, SearchQuery{Query: "needle"})
		if err != nil || len(r.Matches) != 1 || r.Matches[0].Root != link {
			t.Fatalf("only %v: %+v, err %v", only, r.Matches, err)
		}
	}
}
```

Add `"errors"` to the test file's imports (`TestFilesSearchHonoursACancelledContext` uses
`errors.Is`; Task 1 added only `"fmt"` and `"slices"`).

In `cmd/wakil-files/main_test.go`, test that `files_search` is served: write a file with
`needle` and expect one match. Add `"files_search"` to the schema test's list.

- [ ] **Step 2: Run them; they fail**

Run: `go test ./internal/wakilcore/ -run 'TestFilesSearch'`
Expected: FAIL — `undefined: SearchFiles`.

- [ ] **Step 3: Implement**

```go
// SearchCap is the most matches files_search returns (3b-ii).
const SearchCap = 2000

// previewRunes is how much of a matching line a match carries, around the match.
const previewRunes = 400

type SearchQuery struct {
	Query string `json:"query"`
	Case  bool   `json:"case"`
	Word  bool   `json:"word"`
	Regex bool   `json:"regex"`
}

type SearchMatch struct {
	Root    string `json:"root"`
	Path    string `json:"path"`
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	Preview string `json:"preview"`
}

type SearchResult struct {
	Matches   []SearchMatch `json:"matches"`
	Truncated bool          `json:"truncated"`
}

// searchPattern compiles q the one way both kinds of root are searched, so a pattern means the
// same thing inside and outside a repository, and an invalid one is Go's own error (spec).
func searchPattern(q SearchQuery) (*regexp.Regexp, error) {
	p := q.Query
	if !q.Regex {
		p = regexp.QuoteMeta(p)
	}
	if q.Word {
		p = `\b(?:` + p + `)\b`
	}
	if !q.Case {
		p = `(?i)` + p
	}
	re, err := regexp.Compile(p)
	if err != nil {
		return nil, UserError(err.Error())
	}
	return re, nil
}

// utf16Col is the 1-based UTF-16 column of byte offset off in line.
func utf16Col(line string, off int) int {
	return len(utf16.Encode([]rune(line[:off]))) + 1
}

func trimPreview(line string, start, end int) string {
	r := []rune(line)
	if len(r) <= previewRunes {
		return line
	}
	s := utf8.RuneCountInString(line[:start])
	e := s + utf8.RuneCountInString(line[start:end])
	lo := max(0, s-(previewRunes-(e-s))/2)
	hi := min(len(r), lo+previewRunes)
	lo = max(0, hi-previewRunes)
	return string(r[lo:hi])
}

// SearchFiles searches the files ListFiles lists in each root (only, when given, else every
// root): tracked and untracked, never ignored or heavy. Binary files and files over FileCap are
// skipped. It stops at SearchCap and when ctx ends. A match's Root is the root as passed, not
// l.Root (the real path): the app's roots and editor_refresh {root} compare against it.
func SearchFiles(ctx context.Context, roots []string, only []string, q SearchQuery) (SearchResult, error) {
	re, err := searchPattern(q)
	if err != nil {
		return SearchResult{}, err
	}
	targets := roots
	if len(only) > 0 {
		real := realRoots(roots)
		for _, o := range only {
			ro, rerr := filepath.EvalSymlinks(o)
			if rerr != nil || !slices.Contains(real, ro) {
				return SearchResult{}, outsideRoots(o)
			}
		}
		targets = only
	}
	res := SearchResult{Matches: []SearchMatch{}}
	for _, root := range targets {
		l, lerr := ListFiles(ctx, root, roots)
		if lerr != nil {
			return SearchResult{}, lerr
		}
		for _, rel := range l.Files {
			if cerr := ctx.Err(); cerr != nil {
				return SearchResult{}, cerr
			}
			p := filepath.Join(l.Root, filepath.FromSlash(rel))
			info, serr := os.Stat(p)
			if serr != nil || !info.Mode().IsRegular() || info.Size() > FileCap {
				continue
			}
			data, rerr := os.ReadFile(p)
			if rerr != nil || bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
				continue
			}
			for i, line := range strings.Split(string(data), "\n") {
				for _, loc := range re.FindAllStringIndex(line, -1) {
					if loc[0] == loc[1] {
						continue // an empty match marks nothing
					}
					if len(res.Matches) == SearchCap {
						res.Truncated = true
						return res, nil
					}
					res.Matches = append(res.Matches, SearchMatch{
						Root: root, Path: rel, Line: i + 1, Column: utf16Col(line, loc[0]),
						Preview: trimPreview(line, loc[0], loc[1]),
					})
				}
			}
		}
	}
	return res, nil
}
```

Add `"regexp"`, `"slices"` and `"unicode/utf16"` to the imports. Then the tool:

```go
type searchArg struct {
	Roots []string `json:"roots,omitempty" jsonschema:"roots to search (absolute, each a root of the active project); all of them when empty"`
	wakilcore.SearchQuery
}
```

```go
	mcp.AddTool(s, &mcp.Tool{Name: "files_search", Description: "Read-only. Searches the project's files for query (literal unless regex; case-insensitive unless case; whole words with word): each match's root, path (relative), line, column (1-based, UTF-16) and the matching line as preview. Ignored files and the heavy folders are skipped, as are binary files and files over 2 MB. Stops at 2,000 matches (truncated). An invalid regex is Go's own error."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a searchArg) (*mcp.CallToolResult, wakilcore.SearchResult, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.SearchResult{}, nil
			}
			r, err := wakilcore.SearchFiles(ctx, rs, a.Roots, a.SearchQuery)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.SearchResult{}, nil
			}
			return nil, r, nil
		})
```

If the SDK's schema inference rejects an embedded struct (an `AssertObjectOutputSchemas` or
`AddTool` panic), spell the four fields out on `searchArg` and build a `SearchQuery` from them.

- [ ] **Step 4: Run them; they pass**

Run: `go test ./internal/wakilcore/ -run 'TestFiles' && go test ./cmd/wakil-files/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-2-files-search
git add internal/wakilcore cmd/wakil-files docs/architecture/go.md
git commit -m "wakil-files: files_search over the listed files, one Go pattern in every root, capped at 2,000 (3b-ii PR 2)"
```

---

### Task 3: The tree model and the column's persisted state (PR 3)

**Files:**
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (`EditorColumnState`, `EditorColumnView`, `Pane.editorColumn`)
- Modify: `app/Sources/WakilKit/Layout/LayoutStore.swift` (`LayoutSnapshot.editorColumnDefault`, `setEditorColumn`, `editorColumn(id:)`, `editorColumnDefault()`)
- Create: `app/Sources/WakilKit/Editor/EditorTree.swift`
- Test: `app/Tests/WakilKitTests/EditorTreeTests.swift`, `app/Tests/WakilKitTests/LayoutStoreTests.swift`

**Interfaces:**
- Produces (Layout; it must not use `Editor`, so the persisted type lives here as `EditorPosition`
  does):

```swift
public enum EditorColumnView: String, Sendable, Equatable, Codable { case files, search }

/// An editor pane's left column as a layout keeps it (3b-ii). `open` holds absolute paths.
public struct EditorColumnState: Sendable, Equatable, Codable {
    public var shown: Bool
    public var view: EditorColumnView
    public var width: Double
    public var open: [String]
    public static let initial = EditorColumnState(shown: false, view: .files, width: 240, open: [])
    public init(shown: Bool, view: EditorColumnView, width: Double, open: [String])
}
```

- Produces (Layout):
  - `Pane.editorColumn: EditorColumnState?`, persisted in `CodingKeys` and decoded with `try?` in
    the same way as `editorTabs`.
  - `LayoutSnapshot.editorColumnDefault: EditorColumnState?`, persisted and tolerant of a missing
    key.
  - `LayoutStore.setEditorColumn(id: String, to: EditorColumnState)`, which also sets the default
    to `shown`, `view` and `width` with `open: []`.
  - `LayoutStore.editorColumn(id: String) -> EditorColumnState?`
  - `LayoutStore.editorColumnDefault() -> EditorColumnState`, which is `.initial` when none is set.
- Produces (Editor):

```swift
public struct EditorRootListing: Sendable, Equatable {
    public var root: String
    public var files: [String]
    public var ignored: [String]
    public var heavy: [String]
    public var repos: [String]
    public var truncated: Bool
    public var error: String?
    public init(root: String, files: [String], ignored: [String], heavy: [String], repos: [String],
                truncated: Bool, error: String?)
    /// From `files_list`'s structuredContent.
    public init(root: String, content: [String: JSONValue])
    public static func failed(root: String, _ error: String) -> EditorRootListing
}
public struct EditorDirEntry: Sendable, Equatable { public var name: String; public var isDir: Bool }
public enum EditorTreeRowKind: String, Sendable, Equatable { case root, repo, folder, file, note }
public struct EditorTreeRow: Sendable, Equatable, Identifiable {
    public var id: String          // absolute path; a note row is "note:<root>"
    public var root: String
    public var relative: String    // "" for a root
    public var name: String
    public var depth: Int
    public var kind: EditorTreeRowKind
    public var dimmed: Bool        // ignored, or a heavy folder
    public var heavy: Bool
    public var open: Bool
    public var loading: Bool
    public var error: String?      // a root's listing error or a heavy folder's, whole (Rule 8)
}
public func editorTreeRows(_ listings: [EditorRootListing], open: Set<String>,
                           dirs: [String: [EditorDirEntry]], loading: Set<String>,
                           dirErrors: [String: String]) -> [EditorTreeRow]
public func editorTreeSelection(after selected: String?, previous: [EditorTreeRow], now: [EditorTreeRow]) -> String?
public enum EditorTreeMove: Sendable { case up, down }
public func editorTreeStep(_ rows: [EditorTreeRow], selected: String?, _ move: EditorTreeMove) -> String?
public func editorTreeTypeAhead(_ rows: [EditorTreeRow], selected: String?, prefix: String) -> String?
/// ← on a row: close it if it is an open folder, else go to its parent.
public func editorTreeLeft(_ rows: [EditorTreeRow], selected: String) -> (collapse: String?, select: String?)
public func editorColumnWidth(_ width: Double, paneWidth: Double) -> Double
public func editorPruneOpen(_ open: [String], listings: [EditorRootListing]) -> [String]
public func editorFolder(of row: EditorTreeRow) -> String   // a file's folder, or the folder itself
```

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/EditorTreeTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func listing(_ root: String, files: [String] = [], ignored: [String] = [], heavy: [String] = [],
                     repos: [String] = [], truncated: Bool = false, error: String? = nil) -> EditorRootListing {
    EditorRootListing(root: root, files: files, ignored: ignored, heavy: heavy, repos: repos,
                      truncated: truncated, error: error)
}

private func names(_ rows: [EditorTreeRow]) -> [String] {
    rows.map { String(repeating: " ", count: $0.depth) + $0.name + ($0.dimmed ? "~" : "") }
}

@Test func aClosedRootIsOneRow() {
    let rows = editorTreeRows([listing("/p/api", files: ["a.go"])], open: [], dirs: [:], loading: [], dirErrors: [:])
    #expect(names(rows) == ["api"])
    #expect(rows[0].kind == .root && !rows[0].open)
}

@Test func anOpenRootListsFoldersFirstThenFilesEachSorted() {
    let l = listing("/p/api", files: ["z.go", "app/b.php", "a.go", "app/a.php"], ignored: [".env"], heavy: [".git", "vendor"])
    let rows = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(names(rows) == ["api", " .git~", " app", " vendor~", " .env~", " a.go", " z.go"])
    #expect(rows.first { $0.name == "vendor" }?.heavy == true)
}

@Test func aChildRepositoryIsItsOwnNode() {
    let l = listing("/code", files: ["api/main.go", "notes.md"], heavy: ["api/.git"], repos: ["api"])
    let rows = editorTreeRows([l], open: ["/code", "/code/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows.first { $0.name == "api" }?.kind == .repo)
    #expect(names(rows) == ["code", " api", "  .git~", "  main.go", " notes.md"])
}

@Test func anOpenHeavyFolderShowsWhatWasLoadedAndALoadingOneSaysSo() {
    let l = listing("/p/api", files: ["a.go"], heavy: ["vendor"])
    let rows = editorTreeRows([l], open: ["/p/api", "/p/api/vendor"],
                              dirs: ["/p/api/vendor": [EditorDirEntry(name: "laravel", isDir: true), EditorDirEntry(name: "autoload.php", isDir: false)]],
                              loading: [], dirErrors: [:])
    #expect(names(rows) == ["api", " vendor~", "  laravel~", "  autoload.php~", " a.go"])
    let loading = editorTreeRows([l], open: ["/p/api", "/p/api/vendor"], dirs: [:], loading: ["/p/api/vendor"], dirErrors: [:])
    #expect(loading.first { $0.name == "vendor" }?.loading == true)
}

@Test func aFolderInsideAHeavyFolderListsWhatWasLoadedForIt() {
    let l = listing("/p/api", files: ["a.go"], heavy: ["vendor"])
    let rows = editorTreeRows([l], open: ["/p/api", "/p/api/vendor", "/p/api/vendor/laravel"],
                              dirs: ["/p/api/vendor": [EditorDirEntry(name: "laravel", isDir: true)],
                                     "/p/api/vendor/laravel": [EditorDirEntry(name: "framework", isDir: true),
                                                               EditorDirEntry(name: "x.php", isDir: false)]],
                              loading: [], dirErrors: [:])
    #expect(names(rows) == ["api", " vendor~", "  laravel~", "   framework~", "   x.php~", " a.go"])
}

@Test func aTruncatedRootSaysSoAtItsTop() {
    let rows = editorTreeRows([listing("/p/api", files: ["a.go"], truncated: true)], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows[1].kind == .note && rows[1].name == "only the first 50,000 files are listed")
}

@Test func aRootThatFailedCarriesItsErrorWholeAndTheOthersStillList() {
    let rows = editorTreeRows([listing("/p/api", error: "root /p/api is not readable: permission denied"),
                               listing("/p/web", files: ["i.ts"])],
                              open: ["/p/api", "/p/web"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows[0].error == "root /p/api is not readable: permission denied")
    #expect(names(rows) == ["api", "web", " i.ts"])
}

@Test func theSelectionStaysWhenItsRowSurvivesAndFallsToTheNearestWhenItDoesNot() {
    let before = editorTreeRows([listing("/p/api", files: ["a.go", "b.go", "c.go"])], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    let after = editorTreeRows([listing("/p/api", files: ["a.go", "c.go"])], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeSelection(after: "/p/api/a.go", previous: before, now: after) == "/p/api/a.go")
    #expect(editorTreeSelection(after: "/p/api/b.go", previous: before, now: after) == "/p/api/c.go")
    let empty = editorTreeRows([listing("/p/api")], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeSelection(after: "/p/api/c.go", previous: after, now: empty) == "/p/api")
}

@Test func arrowsStepAndTypingJumpsToTheNextNameWithThatPrefix() {
    let rows = editorTreeRows([listing("/p/api", files: ["alpha.go", "beta.go", "bravo.go"])], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeStep(rows, selected: nil, .down) == "/p/api")
    #expect(editorTreeStep(rows, selected: "/p/api/alpha.go", .down) == "/p/api/beta.go")
    #expect(editorTreeStep(rows, selected: "/p/api", .up) == "/p/api")
    #expect(editorTreeTypeAhead(rows, selected: "/p/api/beta.go", prefix: "b") == "/p/api/bravo.go")
    #expect(editorTreeTypeAhead(rows, selected: nil, prefix: "BR") == "/p/api/bravo.go")
}

@Test func leftClosesAnOpenFolderOrGoesToTheParent() {
    let rows = editorTreeRows([listing("/p/api", files: ["app/a.php"])], open: ["/p/api", "/p/api/app"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeLeft(rows, selected: "/p/api/app") == (collapse: "/p/api/app", select: nil))
    #expect(editorTreeLeft(rows, selected: "/p/api/app/a.php") == (collapse: nil, select: "/p/api/app"))
}

@Test func theWidthIsClampedBetween160AndHalfThePane() {
    #expect(editorColumnWidth(100, paneWidth: 1000) == 160)
    #expect(editorColumnWidth(700, paneWidth: 1000) == 500)
    #expect(editorColumnWidth(300, paneWidth: 1000) == 300)
    #expect(editorColumnWidth(240, paneWidth: 300) == 160)   // a narrow pane: the floor wins
}

// Review Focus 5.
@Test func pruneDropsOpenPathsThatNoLongerExist() {
    let l = listing("/p/api", files: ["app/a.php"], heavy: ["vendor"])
    #expect(editorPruneOpen(["/p/api", "/p/api/app", "/p/api/gone", "/p/api/vendor", "/p/old"], listings: [l])
            == ["/p/api", "/p/api/app", "/p/api/vendor"])
}

@Test func pruneKeepsAFolderThatHoldsOnlyAHeavyFolder() {
    let l = listing("/p/api", files: ["a.go"], heavy: ["web/node_modules"])
    #expect(editorPruneOpen(["/p/api/web", "/p/api/web/node_modules"], listings: [l])
            == ["/p/api/web", "/p/api/web/node_modules"])
}

@Test func aListingIsReadFromFilesListsReply() {
    let l = EditorRootListing(root: "/p/api", content: [
        "files": .array([.string("a.go")]), "ignored": .array([.string(".env")]),
        "heavy": .array([.string(".git")]), "repos": .array([]), "truncated": .bool(false)])
    #expect(l == listing("/p/api", files: ["a.go"], ignored: [".env"], heavy: [".git"]))
}
```

Append to `LayoutStoreTests.swift`:

```swift
@Test func anEditorColumnIsSavedPerPaneAndBecomesTheDefaultWithoutItsOpenFolders() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "editor", title: "Editor").id
    let b = await store.open(kind: "editor", title: "Editor").id
    #expect(await store.editorColumnDefault() == .initial)
    let col = EditorColumnState(shown: true, view: .search, width: 300, open: ["/p/api"])
    await store.setEditorColumn(id: a, to: col)
    #expect(await store.editorColumn(id: a) == col)
    #expect(await store.editorColumn(id: b) == nil)
    #expect(await store.editorColumnDefault() == EditorColumnState(shown: true, view: .search, width: 300, open: []))
    let data = try JSONEncoder().encode(await store.snapshot())
    let back = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
    #expect(back.panes.first { $0.id == a }?.editorColumn == col)
    #expect(back.editorColumnDefault?.width == 300)
}
```

(Use the file's existing way of making a store, if it differs from `LayoutStore()`.)

- [ ] **Step 2: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorTreeTests|anEditorColumnIsSaved'`
Expected: compile failure — `cannot find 'editorTreeRows' in scope` and `EditorColumnState`.

- [ ] **Step 3: Implement**

**Layout.** In `Pane.swift`, add `EditorColumnView`, `EditorColumnState` and its memberwise
`init`, next to `EditorSavedTab`. Then make these changes to `Pane`:
- Add `public var editorColumn: EditorColumnState?`, doc-commented in the same way as `editorTabs`.
- Add `editorColumn` to `CodingKeys`.
- Add `editorColumn: EditorColumnState? = nil` to `init`.
- In `init(from:)`: `editorColumn = (try? container.decodeIfPresent(EditorColumnState.self,
  forKey: .editorColumn)) ?? nil`.

In `LayoutStore.swift`:
- Add `public var editorColumnDefault: EditorColumnState?` to `LayoutSnapshot`.
- Add it to its `CodingKeys`.
- Decode it with `decodeIfPresent`, the way `preMaximizeFrames` is decoded.

Then, beside `setEditorTabs`:

```swift
    /// The editor pane `id`'s column (3b-ii), and the window's default for a new pane: what the
    /// operator last left any editor pane in, without its open folders. A no-op when unchanged.
    public func setEditorColumn(id: String, to column: EditorColumnState) {
        guard var current = byScope[scope],
            let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        let fallback = EditorColumnState(shown: column.shown, view: column.view, width: column.width, open: [])
        guard current.panes[index].editorColumn != column || current.editorColumnDefault != fallback else { return }
        current.panes[index].editorColumn = column
        current.editorColumnDefault = fallback
        byScope[scope] = current
    }

    public func editorColumn(id: String) -> EditorColumnState? {
        byScope[scope]?.panes.first(where: { $0.id == id })?.editorColumn
    }

    public func editorColumnDefault() -> EditorColumnState {
        byScope[scope]?.editorColumnDefault ?? .initial
    }
```

**Editor.** In `EditorTree.swift`, the row builder is a recursive walk over a trie built from each
listing. Build one trie per root: insert every `files`, `ignored` and `heavy` path, marking ignored
leaves and heavy folders. Then emit rows, opening only folders whose absolute path is in `open`:

```swift
import Foundation

private final class TreeNode {
    var children: [String: TreeNode] = [:]
    var isDir = false
    var ignored = false
    var heavy = false
}

private func insert(_ rel: String, into root: TreeNode, dir: Bool = false, ignored: Bool = false, heavy: Bool = false) {
    var node = root
    let parts = rel.split(separator: "/").map(String.init)
    for (i, part) in parts.enumerated() {
        let next = node.children[part] ?? TreeNode()
        node.children[part] = next
        if i < parts.count - 1 { next.isDir = true }
        node = next
    }
    node.isDir = node.isDir || dir
    node.ignored = node.ignored || ignored
    node.heavy = node.heavy || heavy
}

public func editorTreeRows(_ listings: [EditorRootListing], open: Set<String>,
                           dirs: [String: [EditorDirEntry]], loading: Set<String>,
                           dirErrors: [String: String]) -> [EditorTreeRow] {
    var rows: [EditorTreeRow] = []
    for l in listings {
        let rootOpen = open.contains(l.root)
        rows.append(EditorTreeRow(id: l.root, root: l.root, relative: "", name: (l.root as NSString).lastPathComponent,
                                  depth: 0, kind: .root, dimmed: false, heavy: false, open: rootOpen,
                                  loading: false, error: l.error))
        guard rootOpen, l.error == nil else { continue }
        if l.truncated {
            rows.append(EditorTreeRow(id: "note:\(l.root)", root: l.root, relative: "", name: "only the first 50,000 files are listed",
                                      depth: 1, kind: .note, dimmed: false, heavy: false, open: false, loading: false, error: nil))
        }
        let trie = TreeNode()
        for f in l.files { insert(f, into: trie) }
        for f in l.ignored { insert(f, into: trie, ignored: true) }
        for h in l.heavy { insert(h, into: trie, dir: true, heavy: true) }
        let repos = Set(l.repos)
        func emit(_ node: TreeNode, prefix: String, depth: Int, dimmed: Bool) {
            let sorted = node.children.sorted { a, b in
                a.value.isDir != b.value.isDir ? a.value.isDir : a.key < b.key
            }
            for (name, child) in sorted {
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let id = "\(l.root)/\(rel)"
                let dim = dimmed || child.ignored || child.heavy
                let isOpen = child.isDir && open.contains(id)
                let kind: EditorTreeRowKind = repos.contains(rel) ? .repo : (child.isDir ? .folder : .file)
                rows.append(EditorTreeRow(id: id, root: l.root, relative: rel, name: name, depth: depth, kind: kind,
                                          dimmed: dim, heavy: child.heavy, open: isOpen,
                                          loading: loading.contains(id), error: dirErrors[id]))
                guard isOpen else { continue }
                if let loaded = dirs[id] {
                    for e in loaded { insert(e.name, into: child, dir: e.isDir) }
                }
                emit(child, prefix: rel, depth: depth + 1, dimmed: dim)
            }
        }
        emit(trie, prefix: "", depth: 1, dimmed: false)
    }
    return rows
}
```

A loaded folder's entries are inserted into its own node, for any **open** row whose id is a key
of `dirs`, not only for heavy rows. So a folder inside a heavy folder (`vendor/laravel`) lists
`dirs["…/vendor/laravel"]` at the next level, once it is opened: Task 5's `editor_tree_expand`
calls `files_list_dir` for any folder at or under a heavy one. Its rows inherit the heavy
folder's dimming through `dimmed`. `aFolderInsideAHeavyFolderListsWhatWasLoadedForIt` pins it.

Then the helpers:

```swift
public func editorTreeSelection(after selected: String?, previous: [EditorTreeRow], now: [EditorTreeRow]) -> String? {
    guard let selected else { return nil }
    if now.contains(where: { $0.id == selected }) { return selected }
    guard let at = previous.firstIndex(where: { $0.id == selected }) else { return now.first?.id }
    let survivors = Set(now.map(\.id))
    if let next = previous[(at + 1)...].first(where: { survivors.contains($0.id) }) { return next.id }
    return previous[..<at].last(where: { survivors.contains($0.id) })?.id ?? now.first?.id
}

public func editorTreeStep(_ rows: [EditorTreeRow], selected: String?, _ move: EditorTreeMove) -> String? {
    guard let i = selected.flatMap({ s in rows.firstIndex { $0.id == s } }) else { return rows.first?.id }
    switch move {
    case .up: return rows[max(0, i - 1)].id
    case .down: return rows[min(rows.count - 1, i + 1)].id
    }
}

public func editorTreeTypeAhead(_ rows: [EditorTreeRow], selected: String?, prefix: String) -> String? {
    let p = prefix.lowercased()
    let start = selected.flatMap { s in rows.firstIndex { $0.id == s } }.map { $0 + 1 } ?? 0
    let order = Array(rows[start...]) + Array(rows[..<start])
    return order.first { $0.kind != .note && $0.name.lowercased().hasPrefix(p) }?.id
}

public func editorTreeLeft(_ rows: [EditorTreeRow], selected: String) -> (collapse: String?, select: String?) {
    guard let row = rows.first(where: { $0.id == selected }) else { return (nil, nil) }
    if row.open { return (row.id, nil) }
    guard row.kind != .root else { return (nil, nil) }
    let parent = (row.id as NSString).deletingLastPathComponent
    return (nil, parent)
}

public func editorColumnWidth(_ width: Double, paneWidth: Double) -> Double {
    max(160, min(width, paneWidth / 2))
}

public func editorPruneOpen(_ open: [String], listings: [EditorRootListing]) -> [String] {
    open.filter { path in
        for l in listings where path == l.root || path.hasPrefix(l.root + "/") {
            if path == l.root { return true }
            let rel = String(path.dropFirst(l.root.count + 1))
            let all = l.files + l.ignored
            // At or under a heavy folder; a folder holding files; or a folder holding only heavy
            // folders (`web` with just `web/node_modules`), which still exists.
            return l.heavy.contains { rel == $0 || rel.hasPrefix($0 + "/") || $0.hasPrefix(rel + "/") }
                || all.contains { $0.hasPrefix(rel + "/") }
        }
        return false
    }
}

public func editorFolder(of row: EditorTreeRow) -> String {
    row.kind == .file ? (row.id as NSString).deletingLastPathComponent : row.id
}
```

`EditorRootListing.init(root:content:)` reads each array of `.string` values, missing keys as
`[]`, and `truncated` with `== .bool(true)`. `.failed(root:_:)` is an empty listing that carries
`error`.

`editorTreeLeft`'s tuple is compared with `==` in the test. Tuples of `Optional<String>` support
`==`, so that compiles.

- [ ] **Step 4: Run them; they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorTreeTests|LayoutStoreTests|Layering'`
Expected: PASS, and the layering test is still green: `Editor` uses `Layout` and `Core`, both
already allowed.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-3-tree-model
git add app/Sources/WakilKit/Layout app/Sources/WakilKit/Editor/EditorTree.swift app/Tests/WakilKitTests/EditorTreeTests.swift app/Tests/WakilKitTests/LayoutStoreTests.swift
git commit -m "Editor: the tree model — rows, keys, selection fallback, width — and the column a layout keeps (3b-ii PR 3)"
```

---

### Task 4: Search and find models; the pane's new fields and `read_pane` (PR 4)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorSearch.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorSnapshot.swift` (`EditorTab.preview`; `EditorSnapshot.column`, `.search`, `.find`, `.findReport`)
- Modify: `app/Sources/WakilKit/Editor/EditorPaneKind.swift` (`read_pane`)
- Modify: `app/Sources/WakilKit/Editor/PaneStore+Editor.swift` (an edit un-previews; `editorFindDidReport`)
- Test: `app/Tests/WakilKitTests/EditorSearchTests.swift`, `EditorReadPaneTests.swift`, `EditorStoreTests.swift`

**Interfaces:**
- Consumes: `EditorColumnState` (Task 3), `EditorRange`, `EditorPosition`.
- Produces:

```swift
public struct EditorSearchMatch: Sendable, Equatable {
    public var root: String; public var path: String; public var line: Int; public var column: Int; public var preview: String
}
public struct EditorSearchState: Sendable, Equatable {
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var inFlight: Bool
    public var serial: Int          // bumps per search started or cancelled; a reply for an older serial is dropped
    public var truncated: Bool
    public var changedSince: Bool
    public var error: String?
    public var results: [EditorSearchMatch]
    public static let empty: EditorSearchState
}
public struct EditorSearchFile: Sendable, Equatable { public var path: String; public var matches: [EditorSearchMatch] }
public struct EditorSearchGroup: Sendable, Equatable { public var root: String; public var files: [EditorSearchFile] }
public func editorSearchGroups(_ results: [EditorSearchMatch]) -> [EditorSearchGroup]
public struct EditorFindRequest: Sendable, Equatable {
    public var query: String; public var caseSensitive: Bool; public var wholeWord: Bool; public var regex: Bool; public var serial: Int
}
public struct EditorFindReport: Sendable, Equatable {
    public var query: String; public var caseSensitive: Bool; public var wholeWord: Bool; public var regex: Bool
    public var count: Int; public var shown: Bool
}
public struct EditorFindError: Error, Sendable, Equatable, CustomStringConvertible { public let description: String }
public func editorFindMatches(_ text: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool) throws -> [EditorRange]
@MainActor public final class EditorDebounce {
    public init(delay: Duration)
    public func schedule(_ body: @escaping @MainActor () async -> Void)
    public func cancel()
}
```

- `EditorTab` gains `public var preview: Bool`, as the last `init` parameter with a default
  (`preview: Bool = false`). `.file(...)` and `.scratch(...)` leave it false.
- `EditorSnapshot` gains:
  - `column: EditorColumnState?` (nil means the pane has never set one, so it follows the layout's
    default);
  - `search: EditorSearchState`;
  - `find: EditorFindRequest?`;
  - `findReport: EditorFindReport?`.
- `init(tabs:active:)` keeps its signature. The new fields default to `nil`, `.empty`, `nil` and
  `nil`.
- `read_pane` on an editor adds:
  - `column` — null, or `{shown, view, width, open}`;
  - `tabs[].preview`;
  - `find` — null, or `{query, case, word, regex, count, shown}`, from `findReport`, else from
    `find` with count null;
  - `search` — `{query, case, word, regex, in_flight, truncated, changed_since, error, results:
    [{root, path, line, column, preview}]}`.
- `PaneStore.editorFindDidReport(paneId: String, report: EditorFindReport)` is a view report, like
  `editorViewDidReport`, and is not a text change.
- `editorBufferDidChange` now also clears `preview` on the tab it writes.

- [ ] **Step 1: Write the failing tests**

`EditorSearchTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func m(_ root: String, _ path: String, _ line: Int) -> EditorSearchMatch {
    EditorSearchMatch(root: root, path: path, line: line, column: 1, preview: "x")
}

@Test func resultsGroupByRootThenFileInTheOrderTheyCame() {
    let g = editorSearchGroups([m("/p/api", "a.php", 1), m("/p/api", "a.php", 9), m("/p/api", "b.php", 2), m("/p/web", "r.ts", 1)])
    #expect(g.map(\.root) == ["/p/api", "/p/web"])
    #expect(g[0].files.map(\.path) == ["a.php", "b.php"])
    #expect(g[0].files[0].matches.map(\.line) == [1, 9])
}

@Test func findIsLiteralAndCaseInsensitiveByDefault() throws {
    let r = try editorFindMatches("Booking\nbooking(\nBOOKINGS", query: "booking(", caseSensitive: false, wholeWord: false, regex: false)
    #expect(r == [EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 9))])
}

@Test func findSwitches() throws {
    let text = "bookingId bookingIdx BookingId"
    #expect(try editorFindMatches(text, query: "bookingId", caseSensitive: true, wholeWord: false, regex: false).count == 2)
    #expect(try editorFindMatches(text, query: "bookingId", caseSensitive: false, wholeWord: true, regex: false).count == 2)
    #expect(try editorFindMatches(text, query: "book\\w+x", caseSensitive: false, wholeWord: false, regex: true).count == 1)
}

@Test func anInvalidFindRegexThrowsItsMessageWhole() {
    #expect(throws: EditorFindError.self) {
        _ = try editorFindMatches("x", query: "book(", caseSensitive: false, wholeWord: false, regex: true)
    }
}

// Review Focus 3.
@Test func findColumnsAreUTF16() throws {
    let r = try editorFindMatches("حجز 😀 bookingId", query: "bookingId", caseSensitive: false, wholeWord: false, regex: false)
    #expect(r.first?.start.column == 8 && r.first?.end.column == 17)
}

@Test func anEmptyFindQueryMatchesNothing() throws {
    #expect(try editorFindMatches("abc", query: "", caseSensitive: false, wholeWord: false, regex: false).isEmpty)
}

@MainActor @Test func theDebounceRunsOnlyTheLastScheduledBodyAfterThePause() async throws {
    let d = EditorDebounce(delay: .milliseconds(30))
    var ran: [Int] = []
    d.schedule { ran.append(1) }
    d.schedule { ran.append(2) }
    try await Task.sleep(for: .milliseconds(120))
    #expect(ran == [2])
    d.schedule { ran.append(3) }
    d.cancel()
    try await Task.sleep(for: .milliseconds(80))
    #expect(ran == [2])
}
```

In `EditorReadPaneTests.swift`, add a test that sets `column`, `search` (with one result) and
`findReport` on a snapshot through `panes.updateEditor(paneId:create:)`. It then reads
`panes.readPane(paneId:kind: "editor")` and expects:
- `column.shown == true` and `column.view == "search"`;
- `search.results[0].path`;
- `find.count`;
- `tabs[0].preview == false`.

In `EditorStoreTests.swift`:

```swift
@Test func typingIntoAPreviewTabKeepsIt() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    var tab = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "a", mtime: 1, language: "go")
    tab.preview = true
    let t = tab
    await panes.updateEditor(paneId: "editor-1", create: true) { s in s.tabs = [t]; s.active = 0 }
    await panes.editorBufferDidChange(paneId: "editor-1", subject: t.subject, text: "ab", basis: 0)
    #expect(await panes.editorSnapshot(paneId: "editor-1").tabs[0].preview == false)
}
```

- [ ] **Step 2: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorSearchTests|EditorReadPaneTests|typingIntoAPreviewTab'`
Expected: compile failure on the new names.

- [ ] **Step 3: Implement**

`EditorSearch.swift`:

```swift
import Foundation

// (the structs listed under Interfaces, with memberwise public inits, and:)

extension EditorSearchState {
    public static let empty = EditorSearchState(query: "", caseSensitive: false, wholeWord: false, regex: false,
                                                inFlight: false, serial: 0, truncated: false, changedSince: false,
                                                error: nil, results: [])
}

public func editorSearchGroups(_ results: [EditorSearchMatch]) -> [EditorSearchGroup] {
    var groups: [EditorSearchGroup] = []
    for r in results {
        if groups.last?.root != r.root { groups.append(EditorSearchGroup(root: r.root, files: [])) }
        var g = groups.removeLast()
        if g.files.last?.path != r.path { g.files.append(EditorSearchFile(path: r.path, matches: [])) }
        g.files[g.files.count - 1].matches.append(r)
        groups.append(g)
    }
    return groups
}

/// Every match of `query` in `text`, as Monaco would mark them: 1-based lines, UTF-16 columns
/// (NSString ranges are UTF-16). Literal unless `regex`; an invalid pattern throws its message whole.
public func editorFindMatches(_ text: String, query: String, caseSensitive: Bool, wholeWord: Bool,
                              regex: Bool) throws -> [EditorRange] {
    guard !query.isEmpty else { return [] }
    var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
    if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
    let re: NSRegularExpression
    do {
        re = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    } catch {
        throw EditorFindError(description: "find: \(query) is not a valid regular expression (\(error.localizedDescription))")
    }
    let ns = text as NSString
    var lineStarts = [0]
    for i in 0..<ns.length where ns.character(at: i) == 10 { lineStarts.append(i + 1) }
    func position(_ offset: Int) -> EditorPosition {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 } }
        return EditorPosition(line: lo + 1, column: offset - lineStarts[lo] + 1)
    }
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        guard m.range.length > 0 else { return nil }
        return EditorRange(start: position(m.range.location), end: position(m.range.location + m.range.length))
    }
}

@MainActor public final class EditorDebounce {
    private let delay: Duration
    private var task: Task<Void, Never>?
    public init(delay: Duration) { self.delay = delay }
    public func schedule(_ body: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let delay = delay
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await body()
        }
    }
    public func cancel() { task?.cancel(); task = nil }
}
```

In `EditorSnapshot.swift`:
- Add `public var preview: Bool` to `EditorTab`, with `preview: Bool = false` as the last `init`
  parameter and `self.preview = preview`.
- Add the four fields to `EditorSnapshot`:

```swift
public struct EditorSnapshot: Sendable, Equatable {
    public var tabs: [EditorTab]
    public var active: Int?
    /// The left column (3b-ii); nil until this pane sets one — it then follows the layout's default.
    public var column: EditorColumnState?
    public var search: EditorSearchState
    /// The last find the agent asked for; the renderer opens Monaco's bar once per serial.
    public var find: EditorFindRequest?
    /// What Monaco's find bar last said (a view report, like the cursor).
    public var findReport: EditorFindReport?
    public static let empty = EditorSnapshot(tabs: [], active: nil)
    public init(tabs: [EditorTab], active: Int?, column: EditorColumnState? = nil,
                search: EditorSearchState = .empty, find: EditorFindRequest? = nil,
                findReport: EditorFindReport? = nil) { … }
}
```

In `EditorPaneKind.readPane`:
- Add `"preview": .bool(tab.preview)` to each tab object.
- Then:

```swift
        o["column"] = s.column.map { c in .object([
            "shown": .bool(c.shown), "view": .string(c.view.rawValue), "width": .number(c.width),
            "open": .array(c.open.map { .string($0) })]) } ?? .null
        let f = s.findReport.map { r in (r.query, r.caseSensitive, r.wholeWord, r.regex, JSONValue.number(Double(r.count)), r.shown) }
            ?? s.find.map { r in (r.query, r.caseSensitive, r.wholeWord, r.regex, JSONValue.null, true) }
        o["find"] = f.map { q, c, w, r, count, shown in .object([
            "query": .string(q), "case": .bool(c), "word": .bool(w), "regex": .bool(r), "count": count, "shown": .bool(shown)]) } ?? .null
        let q = s.search
        o["search"] = .object([
            "query": .string(q.query), "case": .bool(q.caseSensitive), "word": .bool(q.wholeWord), "regex": .bool(q.regex),
            "in_flight": .bool(q.inFlight), "truncated": .bool(q.truncated), "changed_since": .bool(q.changedSince),
            "error": q.error.map { .string($0) } ?? .null,
            "results": .array(q.results.map { m in .object([
                "root": .string(m.root), "path": .string(m.path), "line": .number(Double(m.line)),
                "column": .number(Double(m.column)), "preview": .string(m.preview)]) }),
        ])
```

In `PaneStore+Editor.swift`, inside `editorBufferDidChange`'s write, after `s.tabs[i].edits += 1`,
add `s.tabs[i].preview = false   // an edit keeps a preview tab (spec)`. Then add:

```swift
    /// What Monaco's find bar says now — query, switches, count, shown. A view report like the
    /// cursor's (`editorViewDidReport`), never a text change.
    public func editorFindDidReport(paneId: String, report: EditorFindReport) {
        updateEditor(paneId: paneId) { s in s.findReport = report }
    }
```

- [ ] **Step 4: Run them; they pass, with the editor suite**

Run: `cd app && ../scripts/swift-test.sh --filter 'Editor'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-4-search-find-model
git add app/Sources/WakilKit/Editor app/Tests/WakilKitTests
git commit -m "Editor: search and find models, the preview flag, and the column, search and find in read_pane (3b-ii PR 4)"
```

---

### Task 5: The shared file list; `editor_tree`, `_expand`, `_collapse`; preview opens; restore (PR 5)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorFileLists.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift`, `app/Sources/WakilKit/Editor/EditorPaneKind.swift` (`restoreStep`)
- Modify: `app/Tests/WakilKitTests/EditorTestSupport.swift` (FakeFiles answers `files_list_dir`; `ignored`/`heavy`/`repos` on `files_list`; a parkable `slowList`; `editorFixture` passes `fileLists: nil`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (`fileLists: nil` at the one production call, until Task 7)
- Modify, `fileLists: nil` at each other `registerEditorActions` call so it compiles:
  `app/Tests/WakilKitTests/WindowModelUnsavedScopesTests.swift` (:33),
  `app/Tests/WakilKitTests/WindowModelPaletteTests.swift` (:195 and :221),
  `app/Tests/WakilKitTests/WindowModelEditorTests.swift` (:33, in `editorWindowParts`; Task 7 replaces it
  with the real list)
- Test: `app/Tests/WakilKitTests/EditorTreeActionsTests.swift`

**Interfaces:**
- Consumes: `EditorRootListing`, `EditorDirEntry`, `editorPruneOpen` (Task 3); `EditorSnapshot.column`
  and `EditorTab.preview` (Task 4); `LayoutStore.setEditorColumn`, `editorColumn(id:)` and
  `editorColumnDefault()` (Task 3).
- Produces:

```swift
/// The window's one list per root (3b-ii), feeding ⌘P's files source and every editor pane's tree.
/// A `ToolCaller`: `files_list` is answered from the list while the roots are watched; everything
/// else passes through. Unwatched (no editor pane open), every `files_list` is read fresh and kept
/// nowhere — nothing would tell it the disk changed.
public actor EditorFileLists: ToolCaller {
    public init(files: any ToolCaller)
    public func listing(root: String) async -> EditorRootListing
    /// Drops the root's kept list and loaded folders, bumps its generation so a read already in
    /// flight is never kept, and re-reads the root if it was listed or being listed, so the tree
    /// catches up with the wake that called it.
    public func invalidate(root: String) async
    public func setWatching(_ on: Bool)
    /// Loads one folder at or under a heavy folder (files_list_dir), keyed by its absolute path.
    public func loadDir(root: String, dir: String) async
    public func cancelDir(_ path: String)
    public func state() -> EditorFileListsState
    public func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}
public struct EditorFileListsState: Sendable, Equatable {
    public var listings: [String: EditorRootListing]
    public var dirs: [String: [EditorDirEntry]]
    public var loading: Set<String>
    public var dirErrors: [String: String]
    public static let empty: EditorFileListsState
}
```

- `registerEditorActions(into:panes:layout:files:fileLists:roots:)` gains
  `fileLists: EditorFileLists?`, which has **no default** (the `wakil-never-wired-parameters`
  lesson).
- Actions:

| Action | Kind | Params | Does |
|---|---|---|---|
| `editor_tree` | control | `pane?`, `shown?`, `view?` (`files`/`search`), `width?` | sets the column (from the pane's, else the layout default), persists it, and loads every root's listing when shown on Files |
| `editor_tree_expand` | control | `pane?`, `path` | adds `path` and each parent folder up to its root to `open`; under a heavy folder, loads it through `files_list_dir` |
| `editor_tree_collapse` | control | `pane?`, `path` | removes `path` from `open`; cancels its load if one is in flight |
| `editor_open` | (existing) | adds `preview?` (bool) | `preview: true` puts the file in the pane's preview tab; `preview: false` on an open preview tab keeps it |

- `editor_restore` also restores the column: the layout's `editorColumn`, with `open` pruned
  against the current listings.
- `EditorPaneKind.restoreStep` runs when the pane saved tabs **or** a column.
- Each `editor_tree*` reply is `read_pane` plus `pane`, as every editor action's reply is.

- [ ] **Step 1: Teach FakeFiles the new shapes**

In `EditorTestSupport.swift`, give FakeFiles:
- `var ignoredListing: [String: [String]]` and `var heavyListing: [String: [String]]`, plus
  setters `setIgnored(_:_:)` and `setHeavy(_:_:)`;
- `var dirListing: [String: [(String, Bool)]]` keyed `"<root>/<dir>"`, with `setDir(_:_:)`;
- `slowDir`, parked like `slowRead`, with `releaseDir()`;
- `slowList`, parked like `slowRead` **after** the reply is computed (so a parked read answers
  what the disk held when it started), with `setSlowList(_:)` and `releaseList()`:

```swift
    var slowList = false
    private var listReleased = false
    private var parkedLists: [CheckedContinuation<Void, Never>] = []
    func setSlowList(_ on: Bool) { slowList = on; listReleased = false }
    func releaseList() { listReleased = true; parkedLists.forEach { $0.resume() }; parkedLists = [] }
    private func parkList(_ c: CheckedContinuation<Void, Never>) {
        if listReleased { c.resume() } else { parkedLists.append(c) }
    }
```

In `callTool`, beside the `files_read` park:
`if name == "files_list", slowList { await withCheckedContinuation { c in Task { self.parkList(c) } } }`.

`files_list` adds `"ignored"`, `"heavy"` and `"repos": []`. `files_list_dir` answers
`{root, dir, entries: [{name, kind}]}` from `dirListing["\(root)/\(dir)"]`.

- [ ] **Step 2: Write the failing tests**

`EditorTreeActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func treeFixture() async throws -> (EditorFixture, EditorFileLists) {
    var f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    let registry = ActionRegistry(journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "t")
    await registerEditorActions(into: registry, panes: f.panes, layout: f.layout, files: lists, fileLists: lists,
                                roots: { ["/p/api", "/p/web"] })
    f = EditorFixture(registry: registry, panes: f.panes, layout: f.layout, files: f.files, pane: f.pane)
    await lists.setWatching(true)
    return (f, lists)
}

@Test func showingTheColumnSetsAndPersistsItAndLoadsEveryRoot() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setListing("/p/web", ["i.ts"])
    let reply = try await f.dispatch("editor_tree", ["shown": .bool(true)])
    #expect(await f.snapshot().column == EditorColumnState(shown: true, view: .files, width: 240, open: []))
    #expect(await f.layout.editorColumn(id: f.pane)?.shown == true)
    #expect(await lists.state().listings.keys.sorted() == ["/p/api", "/p/web"])
    #expect(optionalString(reply, "pane") == f.pane)
}

@Test func aNewPaneStartsFromTheLastColumnLeftWithoutItsOpenFolders() async throws {
    let (f, _) = try await treeFixture()
    try await f.dispatch("editor_tree", ["shown": .bool(true), "view": .string("search"), "width": .number(320)])
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_tree", ["pane": .string(other), "view": .string("files")])
    #expect(await f.panes.editorSnapshot(paneId: other).column == EditorColumnState(shown: true, view: .files, width: 320, open: []))
}

@Test func expandOpensThePathAndEveryParentAndCollapseClosesOnlyIt() async throws {
    let (f, _) = try await treeFixture()
    await f.files.setListing("/p/api", ["app/Models/User.php"])
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/app/Models")])
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app", "/p/api/app/Models"])
    try await f.dispatch("editor_tree_collapse", ["path": .string("/p/api/app")])
    #expect(await f.snapshot().column?.open == ["/p/api", "/p/api/app/Models"])
}

@Test func expandingAHeavyFolderLoadsItThroughFilesListDir() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", ["a.go"]); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setDir("/p/api/vendor", [("laravel", true), ("autoload.php", false)])
    try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")])
    #expect(await lists.state().dirs["/p/api/vendor"]?.map(\.name) == ["laravel", "autoload.php"])
    #expect(await f.files.calls.contains("files_list_dir /p/api"))
}

@Test func collapsingAFolderStillLoadingCancelsTheLoad() async throws {
    let (f, lists) = try await treeFixture()
    await f.files.setListing("/p/api", []); await f.files.setHeavy("/p/api", ["vendor"])
    await f.files.setSlowDir(true)
    let expand = Task { try await f.dispatch("editor_tree_expand", ["path": .string("/p/api/vendor")]) }
    while await !lists.state().loading.contains("/p/api/vendor") { await Task.yield() }
    try await f.dispatch("editor_tree_collapse", ["path": .string("/p/api/vendor")])
    await f.files.releaseDir()
    _ = try? await expand.value
    #expect(await lists.state().loading.isEmpty)
    #expect(await lists.state().dirs["/p/api/vendor"] == nil)
}

@Test func treeActionsRefuseAPathOutsideTheRoots() async throws {
    let (f, _) = try await treeFixture()
    do {
        try await f.dispatch("editor_tree_expand", ["path": .string("/etc")])
        Issue.record("expected a refusal")
    } catch {
        #expect(String(describing: error).contains("Invariant 6") && String(describing: error).contains("Decision 36"))
    }
}

@Test func aPreviewOpenReplacesTheCleanPreviewTab() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go"), "preview": .bool(true)])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/b.go"] && s.tabs[0].preview && s.active == 0)
}

// Review Focus 4.
@Test func aPreviewOpenNeverReplacesADirtyTab() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "a!", basis: 0)
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go"), "preview": .bool(true)])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/a.go", "/p/api/b.go"])
    #expect(!s.tabs[0].preview && s.tabs[1].preview)
}

@Test func anAgentEditKeepsThePreviewTab() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    try await f.dispatch("editor_replace_range", ["range": range(1, 1, 1, 1), "text": .string("x")])
    #expect(await f.snapshot().tabs[0].preview == false)
}

@Test func openingAPreviewTabWithoutPreviewKeepsIt() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    #expect(await f.snapshot().tabs[0].preview == false)
}

@Test func aPreviewOpenOfAnAlreadyOpenFileSwitchesToIt() async throws {
    let (f, _) = try await treeFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go"), "preview": .bool(true)])
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "preview": .bool(true)])
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 0 && !s.tabs[0].preview)
}

@Test func restoreBringsTheColumnBackWithMissingFoldersDropped() async throws {
    let (f, _) = try await treeFixture()
    await f.files.setListing("/p/api", ["app/a.php"])
    await f.layout.setEditorColumn(id: f.pane, to: EditorColumnState(shown: true, view: .files, width: 260,
                                                                    open: ["/p/api", "/p/api/app", "/p/api/gone"]))
    try await f.dispatch("editor_restore")
    #expect(await f.snapshot().column == EditorColumnState(shown: true, view: .files, width: 260, open: ["/p/api", "/p/api/app"]))
}

@Test func unwatchedListsAreReadFreshEveryTime() async throws {
    let f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    await f.files.setListing("/p/api", ["a.go"])
    _ = await lists.listing(root: "/p/api")
    await f.files.setListing("/p/api", ["a.go", "b.go"])
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
    await lists.setWatching(true)
    _ = await lists.listing(root: "/p/api")
    await f.files.setListing("/p/api", ["c.go"])
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
    await lists.invalidate(root: "/p/api")
    #expect(await lists.listing(root: "/p/api").files == ["c.go"])
}

// A watcher wake while a files_list is in flight: the stale read lands after the invalidate and
// must not be kept, or the tree never catches up.
@Test func aReadInFlightAcrossAnInvalidateIsNeverKept() async throws {
    let f = try await editorFixture()
    let lists = EditorFileLists(files: f.files)
    await lists.setWatching(true)
    await f.files.setListing("/p/api", ["a.go"])
    await f.files.setSlowList(true)
    let stale = Task { await lists.listing(root: "/p/api") }
    while await !f.files.calls.contains("files_list /p/api") { await Task.yield() }
    await f.files.setListing("/p/api", ["a.go", "b.go"])
    await f.files.setSlowList(false)
    await lists.invalidate(root: "/p/api")          // re-reads: the root was being listed
    await f.files.releaseList()
    _ = await stale.value
    #expect(await lists.state().listings["/p/api"]?.files == ["a.go", "b.go"])
    #expect(await lists.listing(root: "/p/api").files == ["a.go", "b.go"])
}
```

The `range(...)` helper already exists in `EditorTestSupport.swift`.

- [ ] **Step 3: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorTreeActionsTests'`
Expected: compile failure — `cannot find 'EditorFileLists'`, and the extra argument `fileLists`.

- [ ] **Step 4: Implement**

`EditorFileLists.swift`:

```swift
import Foundation

public struct EditorFileListsState: Sendable, Equatable {
    public var listings: [String: EditorRootListing] = [:]
    public var dirs: [String: [EditorDirEntry]] = [:]
    public var loading: Set<String> = []
    public var dirErrors: [String: String] = [:]
    public static let empty = EditorFileListsState()
}

public actor EditorFileLists: ToolCaller {
    private let files: any ToolCaller
    private var watching = false
    private var kept: [String: JSONValue] = [:]            // root -> files_list's raw result, while watched
    private var inFlight: [String: Task<JSONValue, Error>] = [:]
    /// Bumped by `invalidate`: a read that started under an older generation is never kept.
    private var generation: [String: Int] = [:]
    private var dirLoads: [String: Task<Void, Never>] = [:]
    private var current = EditorFileListsState()

    public init(files: any ToolCaller) { self.files = files }

    public func setWatching(_ on: Bool) {
        watching = on
        if !on { kept = [:]; current = EditorFileListsState() }
    }

    public func invalidate(root: String) async {
        let wasListed = current.listings[root] != nil || inFlight[root] != nil
        generation[root, default: 0] += 1
        kept[root] = nil
        inFlight[root] = nil
        for key in current.dirs.keys where key == root || key.hasPrefix(root + "/") { current.dirs[key] = nil }
        if watching, wasListed { _ = await listing(root: root) }
    }

    /// files_list for `root`: kept while watched (one read shared by concurrent callers), fresh otherwise.
    /// A read that an `invalidate` overtook answers its caller but is never kept.
    private func rawList(_ root: String) async throws -> JSONValue {
        if watching, let k = kept[root] { return k }
        if watching, let t = inFlight[root] { return try await t.value }
        let gen = generation[root, default: 0]
        let files = files
        let t = Task { try await files.callTool(name: "files_list", arguments: .object(["root": .string(root)]),
                                                timeout: MCPClient.readReplyTimeout) }
        if watching { inFlight[root] = t }
        defer { if watching, generation[root, default: 0] == gen { inFlight[root] = nil } }
        let value = try await t.value
        if watching, generation[root, default: 0] == gen { kept[root] = value }
        return value
    }

    public func listing(root: String) async -> EditorRootListing {
        let gen = generation[root, default: 0]
        let l: EditorRootListing
        do {
            let raw = try await rawList(root)
            if case .object(let o) = raw, case .bool(true)? = o["isError"] {
                l = .failed(root: root, mcpErrorText(from: o) ?? "files_list failed for \(root)")
            } else if case .object(let o) = raw, case .object(let content)? = o["structuredContent"] {
                l = EditorRootListing(root: root, content: content)
            } else {
                l = .failed(root: root, "files_list answered with no structuredContent")
            }
        } catch {
            l = .failed(root: root, String(describing: error))
        }
        if watching, generation[root, default: 0] == gen { current.listings[root] = l }
        return l
    }

    public func loadDir(root: String, dir: String) async {
        let key = "\(root)/\(dir)"
        dirLoads[key]?.cancel()
        current.loading.insert(key)
        current.dirErrors[key] = nil
        let files = files
        let task = Task { [weak self] in
            let result = try? await files.callTool(name: "files_list_dir", arguments: .object([
                "root": .string(root), "dir": .string(dir)]), timeout: MCPClient.readReplyTimeout)
            guard !Task.isCancelled else { return }
            await self?.finishDir(key, result)
        }
        dirLoads[key] = task
        await task.value
    }

    private func finishDir(_ key: String, _ result: JSONValue?) {
        current.loading.remove(key)
        dirLoads[key] = nil
        guard case .object(let o)? = result else { current.dirErrors[key] = "files_list_dir failed for \(key)"; return }
        if case .bool(true)? = o["isError"] { current.dirErrors[key] = mcpErrorText(from: o) ?? "files_list_dir failed"; return }
        guard case .object(let c)? = o["structuredContent"], case .array(let entries)? = c["entries"] else { return }
        current.dirs[key] = entries.compactMap { e in
            guard case .object(let x) = e, case .string(let name)? = x["name"] else { return nil }
            return EditorDirEntry(name: name, isDir: x["kind"] == .string("dir"))
        }
    }

    public func cancelDir(_ path: String) {
        dirLoads[path]?.cancel()
        dirLoads[path] = nil
        current.loading.remove(path)
    }

    public func state() -> EditorFileListsState { current }

    public func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard name == "files_list", let root = optionalString(arguments, "root") else {
            return try await files.callTool(name: name, arguments: arguments, timeout: timeout)
        }
        return try await rawList(root)
    }
}
```

`mcpErrorText(from:)` and `optionalString` are module-internal helpers that `EditorActions.swift`
already uses.

In `EditorActions.swift`:
- Add `fileLists: EditorFileLists?` to `registerEditorActions`, between `files:` and `roots:`.
- Update the one production caller, `AppWiring.swift:357`, in Task 7. In this task, pass
  `fileLists: nil` there so it compiles. Task 7 replaces that with the real list.
- Update `editorFixture()` (`EditorTestSupport.swift:114`) to pass `fileLists: nil`.
- Pass `fileLists: nil` at the four other test call sites, which otherwise stop compiling:
  `WindowModelUnsavedScopesTests.swift:33`, `WindowModelPaletteTests.swift:195` and `:221`, and
  `WindowModelEditorTests.swift:33` (`editorWindowParts`, which Task 7 gives the real list).
  `grep -rn "registerEditorActions(" app/Sources app/Tests` must then show `fileLists:` on every
  call.

Helpers inside `registerEditorActions`:

```swift
    @Sendable func column(_ pane: String) async -> EditorColumnState {
        if let c = await panes.editorSnapshot(paneId: pane).column { return c }
        return await layout?.editorColumnDefault() ?? .initial
    }

    @Sendable func setColumn(_ pane: String, _ c: EditorColumnState) async {
        await panes.updateEditor(paneId: pane, create: true) { s in s.column = c }
        await layout?.setEditorColumn(id: pane, to: c)
    }

    /// The root holding `path`, and `path` relative to it; refused outside the roots (Rule 7's one refusal).
    @Sendable func treePath(_ raw: String, action: String) async throws -> (path: String, root: String, rel: String) {
        let c = try await confine(raw, action: action)
        return (c.path, c.root, c.path == c.root ? "" : String(c.path.dropFirst(c.root.count + 1)))
    }
```

`editor_tree`:

```swift
    await registry.register(Action(
        name: "editor_tree",
        description: "Show or hide an editor pane's left column (shown), switch its view (files or search), "
            + "or set its width (points; clamped by the view). With no pane, the focused or first editor pane, or "
            + "a new one. A pane that never set its column starts from the one last left in any editor pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["shown": .object(["type": .string("boolean")]),
                        "view": .object(["type": .string("string"), "enum": .array([.string("files"), .string("search")])]),
                        "width": .object(["type": .string("number")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree")
            var c = await column(pane)
            let o = jsonObject(params) ?? [:]
            if case .bool(let shown)? = o["shown"] { c.shown = shown }
            if let v = optionalString(params, "view").flatMap(EditorColumnView.init(rawValue:)) { c.view = v; c.shown = o["shown"] == nil ? true : c.shown }
            if let w = o["width"]?.doubleValue { c.width = max(160, w) }
            await setColumn(pane, c)
            if c.shown, c.view == .files, let fileLists { for r in await roots() { _ = await fileLists.listing(root: r) } }
            return await reply(pane)
        }))
```

If `JSONValue` has no `doubleValue`, use the existing number accessor, or match both `.number(d)`
and `.integer(i)`. The width ceiling of half the pane needs the pane's size, which only the view
knows, so the view clamps with `editorColumnWidth` before it dispatches. The action enforces only
the 160 floor.

`editor_tree_expand`:

```swift
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree_expand")
            guard let raw = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_tree_expand", param: "path")
            }
            let t = try await treePath(raw, action: "editor_tree_expand")
            var c = await column(pane)
            var chain = [t.root]
            var acc = t.root
            for part in t.rel.split(separator: "/") { acc += "/\(part)"; chain.append(acc) }
            for p in chain where !c.open.contains(p) { c.open.append(p) }
            await setColumn(pane, c)
            if let fileLists {
                let l = await fileLists.listing(root: t.root)
                let underHeavy = l.heavy.contains { t.rel == $0 || t.rel.hasPrefix($0 + "/") }
                if underHeavy { await fileLists.loadDir(root: t.root, dir: t.rel) }
            }
            return await reply(pane)
        }
```

`editor_tree_collapse` removes `t.path` from `c.open`, then calls `await
fileLists?.cancelDir(t.path)`. Use `.control` and `.agentReachable` for both. The descriptions name
the refusal: "a path outside the active project's roots is refused (Invariant 6, Decision 36)".

`editor_open`: read `let preview = jsonObject(params)?["preview"] == .bool(true)` and
`let keep = jsonObject(params)?["preview"] == .bool(false)`. In the existing "already open" branch,
when `keep` is set, clear `s.tabs[i].preview`. In the append branch:

```swift
                await panes.updateEditor(paneId: pane, create: true) { s in
                    if let i = s.tabs.firstIndex(where: { $0.path == path }) {
                        s.active = i
                    } else if preview, let p = s.tabs.firstIndex(where: { $0.preview && !$0.dirty }) {
                        var t = tab; t.preview = true
                        s.tabs[p] = t          // the clean preview tab is replaced in place
                        s.active = p
                    } else {
                        var t = tab; t.preview = preview
                        s.tabs.append(t)
                        s.active = s.tabs.count - 1
                    }
                }
```

`editor_replace_range`: after `s.tabs[i].edits += 1`, add `s.tabs[i].preview = false`.

`editor_restore`: after the tabs are re-added, restore the column:

```swift
            if let saved = await layout?.editorColumn(id: pane) {
                var listings: [EditorRootListing] = []
                if let fileLists { for r in await roots() { listings.append(await fileLists.listing(root: r)) } }
                var c = saved
                if !listings.isEmpty { c.open = editorPruneOpen(c.open, listings: listings) }
                let restored = c
                await panes.updateEditor(paneId: pane, create: true) { s in s.column = restored }
            }
```

`EditorPaneKind.restoreStep`:

```swift
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        let hasTabs = !(pane.editorTabs ?? []).isEmpty
        guard hasTabs || pane.editorColumn != nil else { return nil }
        return PaneRestoreStep(action: "editor_restore", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
```

- [ ] **Step 5: Run them; they pass, with the editor suite**

Run: `cd app && ../scripts/swift-test.sh --filter 'Editor|Palette|Layering'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
gh stack add yehia-khalil/3b-ii-5-tree-actions
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "Editor: one file list per root, the tree actions, preview opens and the column's restore (3b-ii PR 5)"
```

---

### Task 6: `editor_find`, `editor_search`, `files_search`; changed-since; the find render step (PR 6)

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift`, `app/Sources/WakilKit/Editor/EditorRenderer.swift`
- Modify: `app/Sources/WakilApp/MonacoEditorRenderer.swift` (a no-op `find`, so WakilApp keeps
  building on PRs 6 and 7; Task 8 fills it)
- Modify: `app/Tests/WakilKitTests/EditorTestSupport.swift` (FakeFiles answers `files_search`, with a parkable `slowSearch` that records a cancelled call)
- Modify: the test renderer double in `EditorRendererTests.swift`, which gains `find`
- Test: `app/Tests/WakilKitTests/EditorSearchActionsTests.swift`, `EditorRendererTests.swift`, `EditorRefreshTests.swift`

**Interfaces:**
- Consumes: `editorFindMatches`, `EditorFindRequest`, `EditorSearchState` and `EditorSearchMatch`
  (Task 4); `EditorFileLists` (Task 5).
- Produces:

| Action | Kind | Params | Does |
|---|---|---|---|
| `editor_find` | control | `pane?`, `query`, `case?`, `word?`, `regex?` | opens Monaco's find bar on the active tab with the query (`snapshot.find`, a new serial) and returns `matches: [{start, end}]` with the pane state |
| `editor_search` | control | `pane?`, `query`, `case?`, `word?`, `regex?`, `cancel?` | runs `files_search` into the pane's Search view; a newer call (or `cancel: true`) supersedes an older one, whose result is dropped |
| `files_search` | read | `query`, `case?`, `word?`, `regex?` | the same search through wakil-files, returning `{matches, truncated}`, drawing nothing |

- `editor_refresh` (existing) marks `search.changedSince` when the refreshed `root` holds any of the
  pane's results. With no `root`, it marks it for any results. It also invalidates nothing itself:
  the window invalidates the list (Task 7).
- The renderer:
  - `EditorRenderer.find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool,
    regex: Bool)`;
  - `EditorRenderStep.find(key:query:caseSensitive:wholeWord:regex:)`;
  - `EditorRendered.findSerial: Int`, an `init` parameter with default `0`.
  - The rendered find serial is **the pane's, not a tab's**: `editorRenderedAfter` records
    `snapshot.find?.serial ?? 0` on **every** key it keeps, and `editorRenderSteps` appends `.find`
    for the active tab only when `snapshot.find?.serial ?? 0` exceeds the highest `findSerial` of
    any rendered key. So a tab first shown after a find never replays it, and switching tabs never
    reopens Monaco's bar with the old query.
  - `MonacoEditorRenderer` (WakilApp) gets an empty `find(...)` in this task, so the protocol
    change does not break the app's build between PRs 6 and 8.

**Ruling recorded here (spec gap):**
- **Cancelling a search is `editor_search {cancel: true}`, not a seventh action.** Rule 4 requires
  a Cancel, Invariant 2 requires it to dispatch, and the spec's action list has no name for it.
  `cancel` keeps the six.
- **"Changed since this search" is per root.** The spec says *"a watcher event on a path in the
  results"*, but the `RootWatcher` reports roots, not paths (`GitWatcher.swift`). So a change under
  a root that holds results marks them. It errs toward offering Re-run.

- [ ] **Step 1: Write the failing tests**

`EditorSearchActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func findReturnsEveryMatchAndAsksMonacoOnce() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "x bookingId\nbookingId")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let reply = try await f.dispatch("editor_find", ["query": .string("bookingId")])
    guard case .object(let o) = reply, case .array(let matches)? = o["matches"] else { Issue.record("no matches"); return }
    #expect(matches.count == 2)
    #expect(await f.snapshot().find == EditorFindRequest(query: "bookingId", caseSensitive: false, wholeWord: false, regex: false, serial: 1))
}

@Test func findWithNoTabOrABadRegexIsRefusedWhole() async throws {
    let f = try await editorFixture()
    await #expect(throws: (any Error).self) { try await f.dispatch("editor_find", ["query": .string("x")]) }
    await f.files.put("/p/api/a.go", "x")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    do {
        try await f.dispatch("editor_find", ["query": .string("book("), "regex": .bool(true)])
        Issue.record("expected the regex error")
    } catch { #expect(String(describing: error).contains("book(")) }
}

@Test func searchFillsThePaneAndFilesSearchDrawsNothing() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 2, 4, "  $bookingId = 1;"), ("/p/web", "r.ts", 1, 7, "const bookingId")])
    try await f.dispatch("editor_search", ["query": .string("bookingId")])
    let s = await f.snapshot().search
    #expect(s.query == "bookingId" && !s.inFlight && s.results.count == 2 && s.error == nil)
    let before = await f.snapshot()
    let reply = try await f.dispatch("files_search", ["query": .string("bookingId")])
    #expect(await f.snapshot() == before)
    guard case .object(let o) = reply, case .array(let m)? = o["matches"] else { Issue.record("no matches"); return }
    #expect(m.count == 2)
}

@Test func aSearchErrorIsShownWholeAndClearsTheResults() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    await f.files.setSearchError("error parsing regexp: missing closing ): `book(`")
    _ = try? await f.dispatch("editor_search", ["query": .string("book("), "regex": .bool(true)])
    let s = await f.snapshot().search
    #expect(s.error == "error parsing regexp: missing closing ): `book(`" && s.results.isEmpty && !s.inFlight)
}

// Review Focus 2.
@Test func aSupersededSearchNeverOverwritesTheNewerResults() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "old.php", 1, 1, "old")])
    await f.files.setSlowSearch(true)
    let first = Task { try await f.dispatch("editor_search", ["query": .string("old")]) }
    while await f.files.calls.filter({ $0.hasPrefix("files_search") }).isEmpty { await Task.yield() }
    await f.files.setSlowSearch(false)
    await f.files.setSearch([("/p/api", "new.php", 1, 1, "new")])
    try await f.dispatch("editor_search", ["query": .string("new")])
    await f.files.releaseSearch()
    _ = try? await first.value
    let s = await f.snapshot().search
    #expect(s.query == "new" && s.results.map(\.path) == ["new.php"] && !s.inFlight)
    #expect(await f.files.calls.contains("files_search cancelled"))   // the older tool call itself stopped
}

// Rule 4: Cancel stops the tool call, not only the pane's wait for it.
@Test func cancelStopsTheSearchInFlight() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    await f.files.setSlowSearch(true)
    let run = Task { try await f.dispatch("editor_search", ["query": .string("x")]) }
    while await f.files.calls.filter({ $0.hasPrefix("files_search") }).isEmpty { await Task.yield() }
    try await f.dispatch("editor_search", ["cancel": .bool(true)])
    await f.files.releaseSearch()
    _ = try? await run.value
    let s = await f.snapshot().search
    #expect(!s.inFlight && s.results.isEmpty)
    #expect(await f.files.calls.contains("files_search cancelled"))
}

@Test func aRefreshUnderARootWithResultsMarksThemChangedSince() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    try await f.dispatch("editor_refresh", ["root": .string("/p/web")])
    #expect(await f.snapshot().search.changedSince == false)
    try await f.dispatch("editor_refresh", ["root": .string("/p/api")])
    #expect(await f.snapshot().search.changedSince == true)
    try await f.dispatch("editor_search", ["query": .string("x")])
    #expect(await f.snapshot().search.changedSince == false)
}
```

FakeFiles gets the following:
- `setSearch([(root, path, line, column, preview)])`, `setSearchError(String?)`,
  `setSlowSearch(Bool)` and `releaseSearch()`, parked in the same way as `slowRead`;
- `files_search` is recorded by `perform`'s existing `"\(name) \(path)"` line (as `"files_search "`,
  so the tests match it by prefix) and answers `{matches: [...], truncated: false}`, or the error as
  `isError` with the text;
- a parked search that was cancelled while it waited records `"files_search cancelled"` and throws
  `CancellationError` once released. A call whose cancellation never reached it returns normally
  and records nothing, which is what the two tests above tell apart.

```swift
    var searchMatches: [(String, String, Int, Int, String)] = []
    var searchError: String?
    var slowSearch = false
    private var searchReleased = false
    private var parkedSearches: [CheckedContinuation<Void, Never>] = []
    func setSearch(_ m: [(String, String, Int, Int, String)]) { searchMatches = m; searchError = nil }
    func setSearchError(_ e: String?) { searchError = e }
    func setSlowSearch(_ on: Bool) { slowSearch = on; searchReleased = false }
    func releaseSearch() { searchReleased = true; parkedSearches.forEach { $0.resume() }; parkedSearches = [] }
    private func parkSearch(_ c: CheckedContinuation<Void, Never>) {
        if searchReleased { c.resume() } else { parkedSearches.append(c) }
    }
```

In `callTool`, after `perform` and beside the `files_read` park:

```swift
        if name == "files_search", slowSearch {
            await withCheckedContinuation { c in Task { self.parkSearch(c) } }
            if Task.isCancelled { calls.append("files_search cancelled"); throw CancellationError() }
        }
```

In `perform`:

```swift
        case "files_search":
            if let searchError {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(searchError)])])])
            }
            return ok(["matches": .array(searchMatches.map { m in .object([
                "root": .string(m.0), "path": .string(m.1), "line": .integer(Int64(m.2)),
                "column": .integer(Int64(m.3)), "preview": .string(m.4)]) }), "truncated": .bool(false)])
```

In `EditorRendererTests.swift`:

```swift
@Test func aFindRequestIsOneStepPerSerial() {
    var s = snapshotWithOneTab()            // the file's existing helper for a one-tab snapshot
    s.find = EditorFindRequest(query: "x", caseSensitive: false, wholeWord: true, regex: false, serial: 1)
    let rendered = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    let key = editorTabKey(s.tabs[0])
    let steps = editorRenderSteps(rendered: rendered, active: key, snapshot: s)
    #expect(!steps.contains { if case .find = $0 { true } else { false } })
    let first = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    #expect(first.contains(.find(key: key, query: "x", caseSensitive: false, wholeWord: true, regex: false)))
}

@Test func aFindIsNotReplayedOnATabFirstShownAfterIt() {
    var s = EditorSnapshot(tabs: [tab("/p/a.go", "a"), tab("/p/b.go", "b")], active: 0)
    s.find = EditorFindRequest(query: "x", caseSensitive: false, wholeWord: false, regex: false, serial: 1)
    let first = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    let rendered = editorRenderedAfter(first, rendered: [:], snapshot: s)
    s.active = 1                                              // b.go has never been rendered
    let switched = editorRenderSteps(rendered: rendered, active: editorTabKey(s.tabs[0]), snapshot: s)
    #expect(!switched.contains { if case .find = $0 { true } else { false } })
    let back = editorRenderedAfter(switched, rendered: rendered, snapshot: s)
    s.active = 0
    #expect(!editorRenderSteps(rendered: back, active: editorTabKey(s.tabs[1]), snapshot: s)
        .contains { if case .find = $0 { true } else { false } })
}
```

`tab(_:_:)` is the file's existing private helper for a file tab.

If the file has no `snapshotWithOneTab()`, build the snapshot inline, as its first test does.

- [ ] **Step 2: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorSearchActionsTests|aFindRequestIsOneStepPerSerial|aFindIsNotReplayed'`
Expected: compile failure, and unknown action `editor_find`.

- [ ] **Step 3: Implement**

The renderer:
- Add `func find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool)`
  to the protocol.
- Add `case find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool)` to
  `EditorRenderStep`.
- Add `public var findSerial: Int` to `EditorRendered`, with an `init` parameter defaulting to 0.

Then, in `editorRenderSteps`, after the existing steps for the active tab:

```swift
        // The pane's rendered find serial: every rendered key carries the same one (editorRenderedAfter).
        var seenFind = 0
        for r in rendered.values { seenFind = max(seenFind, r.findSerial) }
        if let f = snapshot.find, f.serial > seenFind {
            steps.append(.find(key: key, query: f.query, caseSensitive: f.caseSensitive, wholeWord: f.wholeWord, regex: f.regex))
        }
```

This applies in both the `if let r` branch and the new-tab branch. Make the `.find` step the last
one, after `.show` and `.reveal`. In `editorRenderedAfter`, set `findSerial: snapshot.find?.serial
?? 0` on the active tab's new entry, then on every other key left in `out`:

```swift
    let findSerial = snapshot.find?.serial ?? 0
    for key in Array(out.keys) { out[key]?.findSerial = findSerial }
```

In `editorApply`, map `.find` to `renderer.find(...)`. The test double records the call.

In `app/Sources/WakilApp/MonacoEditorRenderer.swift`, beside `reveal`, add the conformance as a
no-op, so WakilApp compiles from this PR on (it has no test target, so nothing else would catch
it until Task 8):

```swift
    // 3b-ii PR 6: the protocol's find step. Task 8 fills it with `wakilFind(...)`.
    func find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool) {}
```

The actions, inside `registerEditorActions`:

```swift
    let flags: [String: JSONValue] = ["query": .object(["type": .string("string")]),
                                      "case": .object(["type": .string("boolean")]),
                                      "word": .object(["type": .string("boolean")]),
                                      "regex": .object(["type": .string("boolean")])]
    @Sendable func flag(_ params: JSONValue, _ k: String) -> Bool { jsonObject(params)?[k] == .bool(true) }

    await registry.register(Action(
        name: "editor_find",
        description: "Find query in the active tab — literal unless regex; case-insensitive unless case; whole "
            + "words with word — opening the pane's find bar on it. Returns every match's range (1-based lines, "
            + "UTF-16 columns) as matches, with the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(flags, required: ["query"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_find")
            guard let query = optionalString(params, "query") else {
                throw StandardActionError.missingParam(action: "editor_find", param: "query")
            }
            let snap = await panes.editorSnapshot(paneId: pane)
            guard let i = editorTabIndex(snap, path: nil) else { throw EditorActionError.noTab(action: "editor_find") }
            let c = flag(params, "case"), w = flag(params, "word"), r = flag(params, "regex")
            let matches = try editorFindMatches(snap.tabs[i].text, query: query, caseSensitive: c, wholeWord: w, regex: r)
            await panes.updateEditor(paneId: pane) { s in
                s.find = EditorFindRequest(query: query, caseSensitive: c, wholeWord: w, regex: r, serial: (s.find?.serial ?? 0) + 1)
            }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["matches"] = .array(matches.map { m in .object([
                "start": .object(["line": .integer(Int64(m.start.line)), "column": .integer(Int64(m.start.column))]),
                "end": .object(["line": .integer(Int64(m.end.line)), "column": .integer(Int64(m.end.column))])]) })
            return .object(o)
        }))
```

For `editor_search`, keep one run per pane in a small actor, so that a newer call, or `cancel`,
cancels the older call's **tool request itself**. The actor holds the task that runs `filesTool`,
not a wrapper around it: cancelling a task that only awaits another task's `value` does not
forward the cancellation, and `files_search` would keep running (Rule 4; "stops when the call's
context is cancelled"). The task is created inside the actor, so it is registered before its
first line runs and a `cancel` can never miss it:

```swift
private actor EditorSearchRuns {
    private var tasks: [String: Task<FilesOutcome, Error>] = [:]
    /// Starts `pane`'s search, cancelling the one before it.
    func start(_ pane: String, _ body: @escaping @Sendable () async throws -> FilesOutcome) -> Task<FilesOutcome, Error> {
        tasks[pane]?.cancel()
        let t = Task { try await body() }
        tasks[pane] = t
        return t
    }
    func cancel(_ pane: String) { tasks[pane]?.cancel(); tasks[pane] = nil }
}
```

`FilesOutcome` is the file's existing `private enum` (EditorActions.swift:40); `EditorSearchRuns` is
`private` at file scope beside it, so it can name it.

Then:

```swift
    let runs = EditorSearchRuns()

    @Sendable func searchArgs(_ params: JSONValue) -> [String: JSONValue] {
        ["query": .string(optionalString(params, "query") ?? ""), "case": .bool(flag(params, "case")),
         "word": .bool(flag(params, "word")), "regex": .bool(flag(params, "regex"))]
    }

    @Sendable func matches(from content: [String: JSONValue]) -> ([EditorSearchMatch], Bool) {
        guard case .array(let list)? = content["matches"] else { return ([], false) }
        let ms: [EditorSearchMatch] = list.compactMap { v in
            guard case .object(let m) = v, case .string(let root)? = m["root"], case .string(let path)? = m["path"] else { return nil }
            let preview: String = { if case .string(let p)? = m["preview"] { p } else { "" } }()
            return EditorSearchMatch(root: root, path: path, line: m["line"]?.intValue ?? 1,
                                     column: m["column"]?.intValue ?? 1, preview: preview)
        }
        return (ms, content["truncated"] == .bool(true))
    }

    await registry.register(Action(
        name: "editor_search",
        description: "Search the project's files for query into an editor pane's Search view (shown): literal "
            + "unless regex, case-insensitive unless case, whole words with word. Ignored files and the heavy "
            + "folders are skipped; at most 2,000 matches (truncated). A newer search, or cancel true, stops the "
            + "one in flight. Returns the pane's state with the results.",
        kind: .control, audience: .agentReachable,
        schema: schema(flags.merging(["cancel": .object(["type": .string("boolean")])]) { a, _ in a }),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_search")
            if flag(params, "cancel") {
                await runs.cancel(pane)
                await panes.updateEditor(paneId: pane, create: true) { s in s.search.serial += 1; s.search.inFlight = false }
                return await reply(pane)
            }
            let files = try requireFiles("editor_search")
            let args = searchArgs(params)
            let serial = await panes.updateEditor(paneId: pane, create: true) { s -> Int in
                s.search.serial += 1
                s.search.query = optionalString(params, "query") ?? ""
                s.search.caseSensitive = flag(params, "case"); s.search.wholeWord = flag(params, "word"); s.search.regex = flag(params, "regex")
                s.search.inFlight = true
                s.search.error = nil
                s.search.changedSince = false
                return s.search.serial
            }
            var c = await column(pane)
            if !c.shown || c.view != .search { c.shown = true; c.view = .search; await setColumn(pane, c) }
            let task = await runs.start(pane) { try await filesTool(files, "files_search", args) }
            let outcome: Result<JSONValue, Error>
            do {
                // The handler's own cancellation reaches the tool call too.
                switch try await withTaskCancellationHandler(operation: { try await task.value },
                                                             onCancel: { task.cancel() }) {
                case .ok(let o): outcome = .success(.object(o))
                case .failed(let text): outcome = .failure(EditorFilesError(description: text))
                }
            } catch { outcome = .failure(error) }
            await panes.updateEditor(paneId: pane) { s in
                guard s.search.serial == serial else { return }        // superseded or cancelled: dropped
                s.search.inFlight = false
                switch outcome {
                case .success(.object(let o)):
                    (s.search.results, s.search.truncated) = matches(from: o)
                case .failure(let e) where !(e is CancellationError):
                    s.search.results = []; s.search.truncated = false
                    s.search.error = String(describing: e)
                default: break
                }
            }
            if case .failure(let e) = outcome, !(e is CancellationError) { throw e }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "files_search",
        description: "Search the project's files for query — the same search editor_search draws — returning "
            + "{matches: [{root, path, line, column, preview}], truncated} without touching any pane.",
        kind: .read, audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object(flags), "required": .array([.string("query")])]),
        handler: { params in
            switch try await filesTool(try requireFiles("files_search"), "files_search", searchArgs(params)) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok(let o): return .object(o)
            }
        }))
```

A cancelled `files_search` maps to `CancellationError` through `filesTool`'s existing catch. The
superseded call's update is dropped by the serial check, which is what Review Focus 2 pins; that
the tool call itself was cancelled is pinned by FakeFiles' `"files_search cancelled"` record in
`cancelStopsTheSearchInFlight` and `aSupersededSearchNeverOverwritesTheNewerResults`.

`editor_refresh`'s check below compares `root` with each result's `root`. That only matches
because Task 2 reports a match's root as passed, not its real path (`/tmp/…`, not
`/private/tmp/…`).

In `editor_refresh`'s final `updateEditor`, append:

```swift
                if !s.search.results.isEmpty, only == nil || s.search.results.contains(where: { $0.root == only }) {
                    s.search.changedSince = true
                }
```

- [ ] **Step 4: Run them; they pass, with the editor suite**

Run: `cd app && ../scripts/swift-test.sh --filter 'Editor'`, then `make app-build`.
Expected: PASS, and WakilApp builds: `MonacoEditorRenderer` conforms through its no-op `find`.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-6-search-actions
git add app/Sources/WakilKit/Editor app/Sources/WakilApp/MonacoEditorRenderer.swift app/Tests/WakilKitTests
git commit -m "Editor: editor_find, editor_search with cancel, files_search, and changed-since on a refresh (3b-ii PR 6)"
```

---

### Task 7: The window — one list for ⌘P and the tree; ignored rows; ⌘B and ⌘⇧F entry points (PR 7)

**Files:**
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (build `EditorFileLists`, pass it to `registerEditorActions`, expose `fileLists` on `WakilWiring`)
- Modify: `app/Sources/WakilApp/WindowSession.swift` (pass `fileLists`; `PaletteClients(files: wiring.fileLists ?? wiring.filesClient)`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Modify: `app/Sources/WakilKit/Command/PaletteEntry.swift` (`isDimmed`), `PaletteSources.swift` (`FilesSource` lists `ignored`), `PaletteSearch.swift` (dimmed ranks last)
- Modify: `app/Tests/WakilKitTests/WindowModelEditorTests.swift` (`editorWindowParts` builds one
  `EditorFileLists` and passes it to both the model and `registerEditorActions`)
- Modify, `fileLists:` at every other call of the public initialiser (the six test calls that pass
  `editorRootWatcher:`, plus `WindowModel.forTesting`):
  `WindowModelUnsavedScopesTests.swift:32`, `OrgSwitchTests.swift:999`, `:1104` and `:1235`,
  `WindowModelGitTests.swift:83` and `WindowModel.swift:1403` take `fileLists: nil`;
  `AppWiringTests.swift:801` takes `fileLists: wiring.fileLists`.
- Test: `app/Tests/WakilKitTests/PaletteFilesSourceTests.swift`, `PaletteSearchTests.swift`, `WindowModelEditorTests.swift`, `AppWiringTests.swift`

**Interfaces:**
- Consumes: `EditorFileLists` and `EditorFileListsState` (Task 5); the actions from Tasks 5 and 6.
- Produces:
  - `PaletteEntry.isDimmed: Bool`, an `init` parameter with default `false`. `FilesSource` sets it
    on ignored rows.
  - `PaletteSearch.rank` sorts dimmed rows after every undimmed match. Ties still keep input order.
  - `WakilWiring.fileLists: EditorFileLists?`
  - `WindowModel`:
    - `fileLists: EditorFileLists?` after `editorRootWatcher:` in both initialisers, following
      `editorRootWatcher` exactly: the internal designated `init` (WindowModel.swift:763) takes it
      as `fileLists: EditorFileLists? = nil`, and the **public convenience `init`**
      (WindowModel.swift:1210, the one `WindowSession.start` and the window tests call) takes it
      with **no default** and passes it through. `forTesting` (WindowModel.swift:1310) passes
      `nil` out loud.
    - `public private(set) var editorFiles: EditorFileListsState`: mirrored after every
      `refreshPanes()`, the view's listings.
    - `public func toggleEditorColumn(_ view: EditorColumnView) async`: ⌘B passes `.files` and
      ⌘⇧F passes `.search`.
    - `public func editorFindDidReport(pane: String, report: EditorFindReport) async`
    - `public var editorColumnDefault: EditorColumnState`, read for a pane that has never set its
      column.
  - The watcher:
    - `editorRootChanged(root)` first calls `await fileLists?.invalidate(root:)`, then dispatches
      `editor_refresh` as today.
    - `syncEditorWatcher` calls `await fileLists?.setWatching(!roots.isEmpty && hasEditor)` after
      its sync.

- [ ] **Step 1: Write the failing tests**

`PaletteFilesSourceTests.swift`. The existing tests build `FilesSource(files: FakeFiles…, roots:)`;
add:

```swift
@Test func ignoredFilesAreListedDimmedAndRankBelowEveryTrackedMatch() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["config/env.php"])
    await files.setIgnored("/p/api", [".env"])
    let rows = await FilesSource(files: files, roots: { ["/p/api"] }).entries()
    #expect(rows.first { $0.title == ".env" }?.isDimmed == true)
    #expect(rows.first { $0.title == "env.php" }?.isDimmed == false)
    let ranked = PaletteSearch.rank(rows, query: "env")
    #expect(ranked.map(\.title) == ["env.php", ".env"])
}
```

This test pins the listing and the dimming, not the rank rule: `identifierFold` keeps the `.`, so
`env.php` already scores as a whole-title prefix and `.env` only as a token prefix, and `env.php`
ranks first with or without the change. The rank rule gets its own test in
`PaletteSearchTests.swift`, where the dimmed row is the better match and comes first in the input:

```swift
@Test func aDimmedRowRanksBelowEveryUndimmedMatchHoweverWellItScores() {
    let dimmed = PaletteEntry(id: "editorfile:/p/api/env.php", group: .resources, title: "env.php", subtitle: "api",
                              kindLabel: "file", verb: "open", action: .focusPane(id: "x"), isDimmed: true)
    let plain = PaletteEntry(id: "editorfile:/p/api/xenv.txt", group: .resources, title: "xenv.txt", subtitle: "api",
                             kindLabel: "file", verb: "open", action: .focusPane(id: "y"))
    #expect(PaletteSearch.rank([dimmed, plain], query: "env").map(\.title) == ["xenv.txt", "env.php"])
}
```

Without the change, `env.php` (a whole-title prefix, and first in the input) ranks first, so this
fails until dimmed rows sort last.

`WindowModelEditorTests.swift`'s fixture is `editorWindowParts(roots:)`, which returns `(model,
watcher, files)`; the fake watcher fires with `fire(_:)`. First change the fixture so the model and
the actions share one real list (with `nil` there, the wake test below cannot pass):

```swift
    let watcher = RecordingRootWatcher()
    let files = FakeFiles()
    let fileLists = EditorFileLists(files: files)
    …
        rootWatcher: nil, editorRootWatcher: watcher, fileLists: fileLists,
        paletteClients: PaletteClients(files: fileLists))
    await registerEditorActions(
        into: registry, panes: panes, layout: layout, files: fileLists, fileLists: fileLists,
        roots: { [weak model] in await model?.gitRootPaths ?? [] })
```

Then add, inside `WindowModelEditorTests`:

```swift
    @Test func cmdBShowsTheFocusedEditorsFilesAndAgainHidesThem() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await model.openPane(kind: "editor")
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.toggleEditorColumn(.files)
        #expect(model.editor(pane)?.column?.shown == true && model.editor(pane)?.column?.view == .files)
        await model.toggleEditorColumn(.search)
        #expect(model.editor(pane)?.column?.view == .search && model.editor(pane)?.column?.shown == true)
        await model.toggleEditorColumn(.search)
        #expect(model.editor(pane)?.column?.shown == false)
    }

    @Test func aWatcherWakeInvalidatesTheListBeforeTheTreeReReadsIt() async throws {
        let (model, watcher, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")             // the watcher starts, and the list is watched
        await model.toggleEditorColumn(.files)
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go"])
        await files.setListing("/p/api", ["a.go", "b.go"])
        await watcher.fire("/p/api")
        #expect(model.editorFiles.listings["/p/api"]?.files == ["a.go", "b.go"])
    }
```

The point of the second test is the order: invalidate (which re-reads a listed root, Task 5),
then refresh, then mirror.

`AppWiringTests.swift`: pin that `WakilWiring.fileLists` exists whenever `filesClient` does, and
that `WindowSession` hands it over. Follow `theWatcherIsActuallyPassedIn`'s pattern.

- [ ] **Step 2: Run them; they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'ignoredFilesAreListedDimmed|aDimmedRowRanksBelow|cmdBShows|aWatcherWakeInvalidates|AppWiringTests'`
Expected: FAIL / compile failure.

- [ ] **Step 3: Implement**

`PaletteEntry`: add `public var isDimmed: Bool`, with an `init` parameter `isDimmed: Bool = false`.

`FilesSource.entries()`: after the tracked rows, add one row per `content["ignored"]` string, in the
same shape, with `isDimmed: true`. Their ids are `"editorfile:\(root)/\(rel)"` as well; a path is
never in both lists.

`PaletteSearch.rank`: change the sort key to dimmed rows last:

```swift
            .sorted { a, b in
                if a.2.isDimmed != b.2.isDimmed { return !a.2.isDimmed }
                return (a.0, -a.1) > (b.0, -b.1)
            }
```

`AppWiring`: after `filesClient` starts, add `let fileLists = filesClient.map { EditorFileLists(files:
$0) }`. Pass `files: fileLists ?? filesClient` and `fileLists: fileLists` to
`registerEditorActions`, and add `fileLists` to `WakilWiring`'s fields and `init`.

`WindowSession.start`: pass `fileLists: wiring.fileLists` and `PaletteClients(…, files:
wiring.fileLists ?? wiring.filesClient)`.

`WindowModel`'s initialisers: add `fileLists: EditorFileLists? = nil` after `editorRootWatcher:`
in the designated `init` (with a comment in `editorRootWatcher`'s style) and store it. Add
`fileLists: EditorFileLists?`, **no default**, after `editorRootWatcher:` in the public
convenience `init`, with the 3b-i comment's reasoning (a tree with no list never lists, with
nothing failing), and pass it through to `self.init`. Then fix every call of the public `init`:
`WindowSession.swift:339` passes `wiring.fileLists`; `editorWindowParts` passes its list (above);
`AppWiringTests.swift:801` passes `wiring.fileLists`; `WindowModelUnsavedScopesTests.swift:32`,
`OrgSwitchTests.swift:999`, `:1104` and `:1235`, `WindowModelGitTests.swift:83` and
`WindowModel.forTesting` (WindowModel.swift:1403) pass `nil`. `grep -rn "editorRootWatcher:"
app/Sources app/Tests` must show `fileLists:` beside every call.

`WindowModel`:

```swift
    /// The shared per-root file list (3b-i's ⌘P source and 3b-ii's trees read one list). Nil in tests
    /// that open no editor; production passes the wiring's, and the designated initialiser has no default.
    private let fileLists: EditorFileLists?
    /// What the trees draw: listings, loaded heavy folders, loads in flight. Mirrored on refreshPanes.
    public private(set) var editorFiles: EditorFileListsState = .empty

    public var editorColumnDefault: EditorColumnState { layoutSnapshot.editorColumnDefault ?? .initial }

    /// ⌘B (`.files`) and ⌘⇧F (`.search`): show the focused editor's column on that view, or hide it when it
    /// already shows it. With no editor focused, the first editor pane, else a new one (editor_tree's own rule).
    public func toggleEditorColumn(_ view: EditorColumnView) async {
        var params: [String: JSONValue] = ["view": .string(view.rawValue)]
        let pane = focusedEditor
        if let pane { params["pane"] = .string(pane) }
        let current = pane.flatMap { editor($0)?.column } ?? editorColumnDefault
        params["shown"] = .bool(!(current.shown && current.view == view))
        if !layoutSnapshot.panes.contains(where: { $0.kind == "editor" }) { await enterConversation() }
        guard let reply = await dispatch("editor_tree", .object(params)) else { return }
        await refreshLayout()
        await refreshPanes()
        if let p = optionalString(reply, "pane"), layoutSnapshot.focusedId != p { await focusPane(id: p) }
    }

    public func editorFindDidReport(pane: String, report: EditorFindReport) async {
        await panes.editorFindDidReport(paneId: pane, report: report)
        await refreshEditor(pane: pane)
    }
```

At the end of `refreshPanes()`, add `if let fileLists { editorFiles = await fileLists.state() }`.
Do the same at the end of `refreshEditor(pane:)`, because a tree action's reply goes through it.

In `editorRootChanged`, add `await fileLists?.invalidate(root: root)` before the dispatch loop. In
`syncEditorWatcher`, after `editorWatcher.sync(...)`, add `await fileLists?.setWatching(hasEditor
&& !roots.isEmpty)`. The guard at its top returns early when there is no `editorWatcher`. In that
case, also call `await fileLists?.setWatching(false)` before returning, so tests without a watcher
read lists fresh.

`dispatchFromSurface` already refreshes after a surface dispatch, so the column's buttons need
nothing more here.

- [ ] **Step 4: Run them; they pass, with everything the window touches**

Run: `cd app && ../scripts/swift-test.sh --filter 'Palette|WindowModelEditor|AppWiring|Editor|Layering'`, then `make app-build`.
Expected: PASS, and WakilApp builds with `WindowSession` passing `fileLists`.

- [ ] **Step 5: Commit**

```bash
gh stack add yehia-khalil/3b-ii-7-window
git add app/Sources/WakilKit app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests
git commit -m "Window: one file list for ⌘P and the trees, ignored files dimmed and ranked last, ⌘B and ⌘⇧F (3b-ii PR 7)"
```

---

### Task 8: Drawing — the column, Search, the menu keys, Monaco's find bar (PR 8)

**Files:**
- Create: `app/Sources/WakilApp/EditorColumn.swift`
- Modify: `app/Sources/WakilApp/EditorPane.swift`, `Canvas.swift`, `AppScene.swift`, `MonacoEditorRenderer.swift`, `monaco-host.html`, `Palettes.swift`

**Interfaces:**
- Consumes:
  - `WindowModel.editorFiles`, `editorColumnDefault`, `toggleEditorColumn` and
    `editorFindDidReport` (Task 7);
  - `editorTreeRows`, `editorTreeStep`, `editorTreeTypeAhead`, `editorTreeLeft`,
    `editorTreeSelection`, `editorColumnWidth` and `editorFolder` (Task 3);
  - `editorSearchGroups` and `EditorDebounce` (Task 4);
  - the actions.
- Produces, as accessibility identifiers for e2e:
  - `editor.column` (container), `editor.column.toggle` (in the tab strip), `editor.column.files`,
    `editor.column.search`, `editor.column.edge`;
  - `editor.tree.row:<root name>/<relative>` and `editor.tree.row:<root name>`;
  - `editor.tree.error:<root name>`, `editor.tree.loading`;
  - `editor.search.query`, `editor.search.case`, `editor.search.word`, `editor.search.regex`,
    `editor.search.cancel`, `editor.search.rerun`, `editor.search.error`, `editor.search.note`;
  - `editor.search.result:<root name>/<path>:<line>`.

WakilApp has no test target. This task's checks are Task 9's e2e and the walk. Every decision it
makes is a Task 3–7 function, which already has tests.

- [ ] **Step 1: Pass the new inputs from Canvas**

In `Canvas.swift`'s `EditorPane(...)` call, add:

```swift
                    files: model.editorFiles,
                    columnDefault: model.editorColumnDefault,
                    findReported: { report in await model.editorFindDidReport(pane: pane.id, report: report) },
```

`EditorPane` gains:
- `let files: EditorFileListsState`;
- `let columnDefault: EditorColumnState`;
- `let findReported: (EditorFindReport) async -> Void`.

`firstRoot` stays, as the save-as fallback.

- [ ] **Step 2: The column view**

`EditorColumn.swift`:

```swift
import WakilKit
import SwiftUI

/// The editor's left column (3b-ii): Files or Search. It decides nothing — rows, steps, selection and
/// width come from WakilKit's tested functions; every change is an `editor_*` action through `dispatch`.
/// Its own state is the selected row (view-local, like a list's highlight), the query being typed and the
/// live drag width.
struct EditorColumn: View {
    let column: EditorColumnState
    /// The tree's rows, built once by `EditorPane` (`treeRows`), which also reads them for save-as.
    let rows: [EditorTreeRow]
    let search: EditorSearchState
    let paneWidth: CGFloat
    let dispatch: (String, [String: JSONValue]) async -> Void
    @Binding var selected: String?

    @State private var dragWidth: Double?
    @State private var query = ""
    @State private var debounce = EditorDebounce(delay: .milliseconds(250))
    @State private var typed = ""
    @State private var lastRows: [EditorTreeRow] = []
    @FocusState private var queryFocused: Bool
    @FocusState private var treeFocused: Bool

    /// The name a row's root goes by in identifiers: `editor.tree.row:<root name>/<relative>`.
    private func rootName(_ row: EditorTreeRow) -> String { (row.root as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if column.view == .files { tree } else { searchView }
            }
            .frame(width: dragWidth ?? editorColumnWidth(column.width, paneWidth: paneWidth))
            edge
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.column")
        .onAppear { if column.view == .search { queryFocused = true } else { treeFocused = true } }
        .onChange(of: column.view) { _, v in if v == .search { queryFocused = true } else { treeFocused = true } }
        .onChange(of: rows) { old, now in selected = editorTreeSelection(after: selected, previous: old, now: now) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Files") { Task { await dispatch("editor_tree", ["view": .string("files"), "shown": .bool(true)]) } }
                .buttonStyle(.plain).opacity(column.view == .files ? 1 : 0.5)
                .accessibilityIdentifier("editor.column.files")
            Button("Search") { Task { await dispatch("editor_tree", ["view": .string("search"), "shown": .bool(true)]) } }
                .buttonStyle(.plain).opacity(column.view == .search ? 1 : 0.5)
                .accessibilityIdentifier("editor.column.search")
            Spacer()
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var edge: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            .padding(.horizontal, 2).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in dragWidth = editorColumnWidth(column.width + g.translation.width, paneWidth: paneWidth) }
                .onEnded { _ in
                    guard let w = dragWidth else { return }
                    Task { await dispatch("editor_tree", ["width": .number(w)]); dragWidth = nil }
                })
            .accessibilityIdentifier("editor.column.edge")
    }
```

The tree is a `ScrollViewReader` over a `LazyVStack` of rows. Each row:
- is indented by `depth * 12`;
- is dimmed with `.opacity(0.45)` when `row.dimmed`;
- shows an italic note row for `.note`;
- shows the error text whole, wrapping, under a root that has `error`, as `editor.tree.error:\(rootName(row))`,
  in the Git pane's root-error style;
- shows `EditorBusyTick` (make it `fileprivate`-free, `internal`) when `row.loading`;
- is outlined in violet when `row.id == selected`.

Clicks and keys:

```swift
    private func activate(_ row: EditorTreeRow, keep: Bool = false) {
        selected = row.id
        switch row.kind {
        case .file:
            Task { await dispatch("editor_open", ["path": .string(row.id), "preview": .bool(!keep)]) }
        case .root, .repo, .folder:
            Task { await dispatch(row.open ? "editor_tree_collapse" : "editor_tree_expand", ["path": .string(row.id)]) }
        case .note: break
        }
    }
```

- A row's `.onTapGesture(count: 2) { activate(row, keep: true) }` comes before
  `.onTapGesture { activate(row) }`.
- `.accessibilityIdentifier("editor.tree.row:\(rootName(row))\(row.relative.isEmpty ? "" : "/" + row.relative)")`.
- `.accessibilityAddTraits(.isButton)`, so `axresolve` can press it.

The tree is `.focusable().focused($treeFocused)` and takes these keys:
- `.onKeyPress(.upArrow)` / `.downArrow` set `selected = editorTreeStep(rows, selected:, .up/.down)`.
- `.rightArrow` expands a closed folder.
- `.leftArrow` uses `editorTreeLeft`: dispatch the collapse, or move the selection.
- `.return` calls `activate`.
- `.onKeyPress(characters: .alphanumerics.union(.punctuationCharacters))` appends to `typed`, and
  resets it after 800 ms with no key: `selected = editorTreeTypeAhead(rows, selected:, prefix:
  typed)`.

Each returns `.handled`.

The Search view:
- `TextField("Search files", text: $query)`, `.focused($queryFocused)`,
  `.accessibilityIdentifier("editor.search.query")`.
- `.onChange(of: query) { _, q in debounce.schedule { await runSearch(q) } }` (Rule 2).
- `.onSubmit { debounce.cancel(); Task { await runSearch(query) } }`.
- `.onAppear { query = search.query }`.
- Three toggles: `Aa` (`editor.search.case`), `ab` with a word mark (`editor.search.word`) and `.*`
  (`editor.search.regex`). Each re-runs the search at once.
- While `search.inFlight`: the busy tick and a `Cancel` button (`editor.search.cancel`), which
  dispatches `editor_search {cancel: true}`.
- `search.error`: whole, wrapping (`editor.search.error`).
- `search.truncated`: *"only the first 2,000 matches are shown"* (`editor.search.note`).
- `search.changedSince`: *"files changed since this search"* and a `Re-run` button
  (`editor.search.rerun`).
- Results: `editorSearchGroups(search.results)`, a root header, then a file name, then
  `"\(m.line)  \(m.preview)"` rows, each `editor.search.result:<root name>/<path>:<line>`, where the
  root name is `(m.root as NSString).lastPathComponent`, as `rootName` gives a tree row. Clicking
  one opens it:

```swift
    private func open(_ m: EditorSearchMatch) {
        Task {
            await dispatch("editor_open", ["path": .string("\(m.root)/\(m.path)"), "line": .integer(Int64(m.line)),
                                           "column": .integer(Int64(m.column)), "preview": .bool(true)])
            await dispatch("editor_find", ["query": .string(search.query), "case": .bool(search.caseSensitive),
                                           "word": .bool(search.wholeWord), "regex": .bool(search.regex)])
        }
    }

    private func runSearch(_ q: String) async {
        guard !q.isEmpty else { return }
        await dispatch("editor_search", ["query": .string(q), "case": .bool(search.caseSensitive),
                                         "word": .bool(search.wholeWord), "regex": .bool(search.regex)])
    }
```

The toggles pass the flipped value for their own switch in the same call.

↑↓ through results uses the same pattern as the tree. It keeps a local selected result id, and
Return opens it. Rule 6: switching back to Search keeps the results and their selection.

- [ ] **Step 3: Put the column in the pane**

In `EditorPane.body`, wrap the existing `VStack` in an `HStack(spacing: 0)` whose leading child is:

```swift
            if column.shown {
                EditorColumn(column: column, rows: treeRows, search: snapshot.search,
                             paneWidth: paneWidth, dispatch: dispatch, selected: $treeSelected)
            }
```

- `column` is `snapshot.column ?? columnDefault`.
- `treeRows` is the tree's rows, lifted out of `EditorColumn` so the save-as default below reads
  the same rows the column draws:

```swift
    private var treeRows: [EditorTreeRow] {
        editorTreeRows(roots.compactMap { files.listings[$0] }, open: Set(column.open), dirs: files.dirs,
                       loading: files.loading, dirErrors: files.dirErrors)
    }
```

- `roots` is the window's roots in order. Pass `roots: model.gitRootPaths` from Canvas as a new
  `let roots: [String]` on `EditorPane`.
- `paneWidth` comes from a `GeometryReader` around the `HStack`.
- `@State private var treeSelected: String?`.

The tab strip gets a leading toggle, so the column can always be shown again:

```swift
            Button { Task { await dispatch("editor_tree", ["shown": .bool(!column.shown), "view": .string(column.view.rawValue)]) } }
                label: { Image(systemName: "sidebar.left").font(.system(size: 11)) }
                .buttonStyle(.plain).opacity(column.shown ? 0.9 : 0.5)
                .help("Files ⌘B · Search ⌘⇧F")
                .accessibilityIdentifier("editor.column.toggle")
```

Draw the strip, with this toggle, even when `snapshot.tabs` is empty. Otherwise an empty pane would
have no way to show the column except ⌘B.

The tab title is `.italic(tab.preview)`. A double-click on a tab (`.onTapGesture(count: 2)`)
dispatches `editor_open {path, preview: false}` for a file tab.

Save-as default:
- Compute `saveAsBase = treeSelected.flatMap { id in treeRows.first { $0.id == id } }.map(editorFolder(of:)) ?? firstRoot`.
- Replace the `firstRoot`-based prefill and its `.onChange(of: firstRoot)` follow with `saveAsBase`.
  Keep the 3b-i rule that a typed path is never overwritten: only follow while the field still
  holds the old base plus "/".

Keyboard ownership:
- When the column has focus, Monaco must not take it back. The 3b-i `.onChange(of: snapshot)`
  focuses the host when the active tab changes. That stays: opening a file from the tree is a new
  front tab, and the editor taking the keyboard is the 3b-i Rule 3 behaviour.
- A **preview** open from the tree is browsing, though. Skip `host.focus()` when the new active tab
  is `preview`, so ↑↓ keeps moving through the tree. Check with `now.tabs[i].preview`.

- [ ] **Step 4: The menu keys and the page's key passthrough**

`AppScene.swift`, beside ⌘T:

```swift
                // 3b-ii. ⌘B shows or hides the focused editor's Files; ⌘⇧F its Search. With no editor
                // focused, the first editor pane, else a new one (editor_tree's own rule).
                Button("Show Files") {
                    withModel { model in Task { await model.toggleEditorColumn(.files) } }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Search Files") {
                    withModel { model in Task { await model.toggleEditorColumn(.search) } }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
```

Update the comment listing the window's bound keys under ⌘⇧O so that it includes ⌘B and ⌘⇧F.

In `monaco-host.html`'s editor-mode `keydown` listener, the window's menu commands must reach the
app while Monaco keeps ⌘F, ⌘G and ⌥⌘F:

```js
      window.addEventListener('keydown', function (e) {
        if (!e.metaKey || e.ctrlKey || e.altKey) return;
        const plain = ['KeyS', 'KeyT', 'KeyW', 'KeyP', 'KeyK', 'KeyB'].indexOf(e.code) >= 0 && !e.shiftKey;
        const searchFiles = e.code === 'KeyF' && e.shiftKey;
        if (plain || searchFiles) { e.stopPropagation(); }
      }, true);
```

The existing rule ignored shift for the five keys. Check that no current menu command uses ⇧ with
those five keys (`grep -n 'modifiers: \[.command, .shift\]' AppScene.swift`): today only ⌘⇧D and
⌘⇧O exist. If a ⇧ variant of one of the five keys is ever added, it needs its own entry.

- [ ] **Step 5: Monaco's find bar — colours, the agent's find and its report**

In the `wakil` theme's `colors`, add §5's tokens:

```js
        'editorWidget.background': '#11141e',
        'editorWidget.border': '#2a2f40',
        'input.background': '#0b0d14',
        'input.foreground': '#e8ecf6',
        'input.border': '#2a2f40',
        'inputOption.activeBorder': '#7c5cff',
        'inputOption.activeBackground': '#7c5cff33',
        'focusBorder': '#7c5cff',
        'editor.findMatchBackground': '#7c5cff55',
        'editor.findMatchHighlightBackground': '#7c5cff26',
        'editor.findRangeHighlightBackground': '#7c5cff14'
```

In editor mode, after `window.wakilFocus`:

```js
      const findCtl = ed.getContribution('editor.contrib.findController');
      function reportFind() {
        if (!current || !findCtl) return;
        const st = findCtl.getState();
        post({ type: 'find', query: st.searchString, matchCase: st.matchCase, wholeWord: st.wholeWord,
               isRegex: st.isRegex, count: st.matchesCount, shown: st.isRevealed });
      }
      if (findCtl) findCtl.getState().onFindReplaceStateChange(reportFind);
      // The agent's editor_find: the bar opens on its query, switches set, the first match revealed.
      window.wakilFind = function (key, q, matchCase, wholeWord, isRegex) {
        if (key !== current || !findCtl) return;
        findCtl.getState().change({ searchString: q, matchCase: matchCase, wholeWord: wholeWord,
                                    isRegex: isRegex, isRevealed: true }, false);
        findCtl.start({ forceRevealReplace: false, seedSearchStringFromSelection: 'none',
                        seedSearchStringFromNonEmptySelection: false, seedSearchStringFromGlobalClipboard: false,
                        shouldFocus: 0, shouldAnimate: true, updateSearchScope: false, loop: true });
        findCtl.moveToNextMatch();
      };
```

Before relying on those names, verify them against the bundled Monaco:

```bash
grep -o "editor.contrib.findController" app/Sources/WakilApp/monaco/vs/editor/editor.main.js | head -1
grep -o "seedSearchStringFromSelection" app/Sources/WakilApp/monaco/vs/editor/editor.main.js | head -1
grep -o "onFindReplaceStateChange" app/Sources/WakilApp/monaco/vs/editor/editor.main.js | head -1
```

Each must print the name. In Monaco 0.52, `seedSearchStringFromSelection` takes `'none' | 'single'
| 'multiple'`. If the bundle shows a boolean, pass `false` instead.

Esc closing the bar and leaving the cursor on the match is Monaco's own behaviour, so no code is
needed.

`MonacoEditorRenderer`:
- Replace Task 6's no-op `func find(key:query:caseSensitive:wholeWord:regex:)` with one that runs
  `wakilFind(...)`.
- `var onFind: ((EditorFindReport) -> Void)?`
- In `receive`, add `case "find":`. It builds an `EditorFindReport` from `query`, `matchCase`,
  `wholeWord`, `isRegex`, `count` and `shown`, and calls `onFind`.

`EditorHost` sets `renderer.onFind = { r in Task { await findReported(r) } }` in the same way it
wires `onView`. That is the view-report path (`PaneStore.editorFindDidReport`), not typing.

- [ ] **Step 5b: Palette rows**

In `Palettes.swift`'s row view, apply `.opacity(entry.isDimmed ? 0.5 : 1)` to the title and
subtitle, as `isCaution` styles the subtitle.

- [ ] **Step 6: Build, then look at it once**

Run: `make build && make app-bundle`
Expected: both succeed.

Then the controller launches the bundle once against a two-root project, the way the 3b-i walk's
§0 does. Ask the operator first: the GUI is shared (memory `shared-gui-between-sessions`). Confirm:
- ⌘B, ⌘⇧F and the toggle;
- a dimmed `.env`;
- that a heavy folder loads.

Fix anything that does not draw before committing.

- [ ] **Step 7: Commit**

```bash
gh stack add yehia-khalil/3b-ii-8-column-ui
git add app/Sources/WakilApp
git commit -m "Editor pane: the left column — Files, Search, the drag edge — ⌘B and ⌘⇧F, and Monaco's find bar in Wakil's colours (3b-ii PR 8)"
```

---

### Task 9: Charter, e2e checks, the acceptance runbook (PR 9)

**Files:**
- Modify: `docs/wakil/design-language.md`:
  - §1, principle 1: name the editor's left column as the second sanctioned exception. Unlike the
    Git column, it is shown and hidden only by the operator or the agent, never by width.
  - §11, the Editor entry: replace the File tree bullet with the column's two views, the preview
    tab, search and find.
  - §15: close any open item about a project-explorer pane if it is answered.
- Modify: `docs/wakil/decisions.md`: add **Decision 37** after 36, in its numbered style. It records:
  - root focus dropped, and why;
  - Changes' collapsible groups (3b-iii);
  - file operations as 3b-iv;
  - editor settings, with autosave, as 3b-v;
  - the renumbering of the later rows.

  Its **Reverse if** is: *"a cross-file feature needs per-pane scoping that collapse cannot give"*.
- Modify: `docs/superpowers/specs/2026-10-11-3b-i-editor-core-design.md`: in its roadmap note on root
  focus, add *"(Dropped in 3b-ii — Decision 37.)"*.
- Modify: `docs/architecture/wakilkit.md`: the Editor folder's new files, in the section's existing
  style. Then `CONTRIBUTING.md` only if it lists the editor's files.
- Modify: `e2e/driver/seedgit.go`. In `e2e-api`'s first commit, write `.gitignore` (`".env\nvendor/\n"`),
  `.env` (`"DB_PASSWORD=e2e\n"`) and `vendor/autoload.php` (`"<?php\n"`).
  - Ignored files never show in `git status`, so no 3a-i check changes. Confirm by running the five
    `3a-i-git-*` checks.
  - Also commit the search-Cancel check's haystack, `bulk/000.txt`…`bulk/199.txt` (1 MiB each),
    with the first commit. Committed and clean, it shows in no `git status`; nothing in it matches
    any other check's query.
  - `seedRepo` writes `filepath.Join(dir, name)` without making parent folders, so give it an
    `os.MkdirAll(filepath.Dir(path), 0o755)` before each write; `vendor/autoload.php` and `bulk/…`
    need it.
- Create these seeded checks. Each starts with `{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}`,
  then `editor_new_scratch` to have `editor-1`, as 3a-i's checks open the git project:
  - `e2e/checks/seeded/3b-ii-tree-toggle.jsonl`;
  - `3b-ii-tree-preview.jsonl`;
  - `3b-ii-tree-ignored-heavy.jsonl`;
  - `3b-ii-palette-ignored.jsonl`;
  - `3b-ii-search.jsonl` (with the `editor_search` and `editor_find` parity steps);
  - `3b-ii-search-errors.jsonl`;
  - `3b-ii-search-cancel.jsonl`;
  - `3b-ii-find.jsonl`;
  - `3b-ii-tree-live.jsonl`;
  - `3b-ii-refusals.jsonl`.
- Modify: `e2e/checks/uncoverable.tsv`, with the excuses below.
- Create: `docs/wakil/phase-3b-ii-acceptance.md`.
- Proofs: `e2e/checks/proofs/3b-ii-*.json` (written by `make e2e-new`).

- [ ] **Step 1: Write the checks**

`3b-ii-tree-toggle.jsonl`:

```jsonl
{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}
{"expect":{"tree":"contains","text":"e2e-git"}}
{"dispatch":{"action":"editor_new_scratch","params":{}}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"1"}}
{"do":{"hotkey":"cmd+b"}}
{"expect":{"pane":"editor-1","field":"column.shown","equals":"true"}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"files"}}
{"expect":{"tree":"contains","text":"e2e-api"}}
{"do":{"hotkey":"cmd+shift+f"}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"search"}}
{"do":{"click":"editor.column.toggle"}}
{"expect":{"pane":"editor-1","field":"column.shown","equals":"false"}}
{"dispatch":{"action":"editor_tree","params":{"pane":"editor-1","shown":true,"view":"files"}}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"files"}}
{"parity":{"action":"editor_tree","params":{"pane":"editor-1","shown":true,"view":"search"},"click":"editor.column.search","assert":"read_pane"}}
{"expect":{"journal":{"contains":"\"action\":\"editor_tree\""}}}
```

`(*Runner).parity` in `e2e/driver/run.go` runs the UI half first and refuses the step unless the
click changes the state it read before (the `Parity` step itself is defined in
`e2e/driver/check.go`). So the dispatch just before it shows the column on **Files**:
`editor.column.search` then exists, and pressing it changes `column.view` to `search`, which the
dispatch half repeats.

`3b-ii-tree-preview.jsonl`:
- show the column (`cmd+b`);
- click `editor.tree.row:e2e-api` and expect the tree to contain `README.md`;
- click `editor.tree.row:e2e-api/README.md`, then expect `tabs[1].path` contains
  `/e2e-api/README.md` and `tabs[1].preview` equals `true`;
- click `editor.tree.row:e2e-api/app.txt` and expect `tabs[1].path` contains `/e2e-api/app.txt`,
  with `tabs` length 2 (replaced in place);
- dispatch `editor_open {path: "{fixtureRoot}/e2e-api/app.txt", preview: false}` and expect
  `tabs[1].preview` equals `false`;
- click `editor.tree.row:e2e-api/README.md` and expect `tabs[2].preview` equals `true`.

`3b-ii-tree-ignored-heavy.jsonl`:
- open `e2e-api`, then expect the tree to contain `.env` and `vendor`;
- expect the tree to be absent `autoload.php`;
- click `editor.tree.row:e2e-api/vendor`, then expect the journal to contain `editor_tree_expand`
  and the tree to contain `autoload.php`;
- click `editor.tree.row:e2e-api/.env` and expect `tabs[1].path` contains `/e2e-api/.env`.

`3b-ii-palette-ignored.jsonl`:
- `cmd+p`, then keys `.env`;
- expect the tree to contain `.env`;
- Return, then expect `tabs[1].path` contains `/e2e-api/.env`.

`3b-ii-search.jsonl`:
- dispatch `editor_save {as: "{fixtureRoot}/e2e-portal/needle.txt"}` from a scratch with `needle in
  portal`. Do the same into `e2e-api/needle.txt`;
- `cmd+shift+f`, keys `needle`;
- expect `search.results` contains `needle.txt`, and the tree contains
  `editor.search.result:e2e-api` and `e2e-portal` text;
- the `editor_search` parity (the spec's Testing list). Its UI half is the whole-word switch, which
  re-runs the search with `word` flipped on, so the state changes (`search.word`); the dispatch
  half runs the same search:

```jsonl
{"expect":{"pane":"editor-1","field":"search.word","equals":"false"}}
{"parity":{"action":"editor_search","params":{"pane":"editor-1","query":"needle","word":true},"click":"editor.search.word","assert":"read_pane"}}
{"expect":{"pane":"editor-1","field":"search.word","equals":"true"}}
```

- the `editor_find` parity (the spec's Testing list). Its UI half is a click on the result, which
  dispatches `editor_open` and then `editor_find` with the Search view's query and switches; the
  dispatch half repeats the find on the tab the click opened. `needle.txt` holds one match, so
  Monaco's `moveToNextMatch` leaves the cursor where the click put it, and both halves read back
  the same `find` report:

```jsonl
{"parity":{"action":"editor_find","params":{"pane":"editor-1","query":"needle","word":true},"click":"editor.search.result:e2e-portal/needle.txt:1","assert":"read_pane"}}
{"expect":{"pane":"editor-1","field":"find.query","equals":"needle"}}
{"expect":{"pane":"editor-1","field":"find.word","equals":"true"}}
```

- then expect the active tab's path contains `/e2e-portal/needle.txt`.

Use the search result's visible text, not its identifier, in the tree asserts: the tree lists text
(Orca omits identifiers).

`3b-ii-search-errors.jsonl`:
- `cmd+shift+f`, click `editor.search.regex`, keys `book(`;
- expect the tree to contain `missing closing )`;
- expect `search.error` contains `missing closing )`.
- Cancel has its own check, `3b-ii-search-cancel.jsonl`, below.

`3b-ii-search-cancel.jsonl` (Rule 4, the spec's Testing list: "Cancel stops a search"). The query
matches nothing, so the search reads every committed `bulk/` file. Typing first starts a literal
search after the 250 ms pause; the regex switch then re-runs it as a pattern with no literal
prefix, the slow case, superseding the first:

```jsonl
{"dispatch":{"action":"ctx_set_project","params":{"name":"e2e-git"}}}
{"expect":{"tree":"contains","text":"e2e-git"}}
{"dispatch":{"action":"editor_new_scratch","params":{}}}
{"expect":{"pane":"editor-1","field":"tabs[0].scratch","equals":"1"}}
{"do":{"hotkey":"cmd+shift+f"}}
{"expect":{"pane":"editor-1","field":"column.view","equals":"search"}}
{"do":{"keys":"\\w+zq\\d"}}
{"do":{"click":"editor.search.regex"}}
{"expect":{"pane":"editor-1","field":"search.in_flight","equals":"true"}}
{"do":{"click":"editor.search.cancel"}}
{"expect":{"pane":"editor-1","field":"search.in_flight","equals":"false"}}
{"expect":{"pane":"editor-1","field":"search.results","equals":"[]"}}
{"expect":{"journal":{"contains":"\"cancel\":true"}}}
```

Before committing it, **measure** one run: `make e2e-new` with only this check. If the search
already finishes before the `in_flight` expect or the Cancel press can land, first make the
haystack bigger (more `bulk/` files, each under the 2 MB `FileCap` that search skips above). Only
if a measured run still shows the search finishing first, drop the check and excuse
`editor.search.cancel` in `e2e/checks/uncoverable.tsv`, citing the measurement and the
`editor.saving.cancel` precedent (a control that exists only while a call is in flight, which a
press cannot reach). Cancelling a search is then the walk's, and the unit test
`cancelStopsTheSearchInFlight` pins that the tool call itself stops.

In `seedgit.go`, the haystack:

```go
// searchBulk is 3b-ii-search-cancel's haystack: enough text that a regex search over the git
// project is still running when a press on Cancel lands. Committed with the first seed, so no
// git-status check sees it, and no other check's query matches a line of it.
const searchBulkFiles, searchBulkBytes = 200, 1 << 20

func searchBulk() map[string]string {
	line := "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor\n"
	body := strings.Repeat(line, searchBulkBytes/len(line))
	m := make(map[string]string, searchBulkFiles)
	for i := 0; i < searchBulkFiles; i++ {
		m[fmt.Sprintf("bulk/%03d.txt", i)] = body
	}
	return m
}
```

It is one more write step before `e2e-api`'s first `add -A`: `{write: searchBulk()}`.

`3b-ii-find.jsonl`:
- `editor_open` `{fixtureRoot}/e2e-api/app.txt`;
- dispatch `editor_find {query: "line"}`;
- expect `find.query` equals `line` and `find.count` equals `3`. Monaco's own report counts three
  lines that contain `line`;
- the reply's matches are pinned by unit tests.

`3b-ii-tree-live.jsonl`:
- show the tree and open `e2e-api`;
- from a second editor pane (`pane_open {kind: "editor"}`, then a scratch), save
  `{fixtureRoot}/e2e-api/born.txt`. This is the disk-changed precedent: the dispatched-terminal
  route is #401;
- expect the tree to contain `born.txt`, after the settle wait.

`3b-ii-refusals.jsonl`: dispatch `editor_tree_expand {path: "/etc"}` and `editor_tree_collapse {path: "/etc"}` and expect each dispatch error to contain `Invariant 6`, in the expect-error form `3b-i-editor-refusals.jsonl` uses (`files_list_dir`'s own refusal is pinned by `TestFilesListDirRefusesAFolderOutsideTheRoot`).

`uncoverable.tsv`: add one line per item in the existing two-column form. Each names the check that
covers the rest:
- `editor_tree_expand` and `editor_tree_collapse` parity: the click toggles, so the second half
  undoes the first. Both channels are covered separately.
- `editor.column`: a container.
- `editor.column.edge`: a drag that resizes. Covered by the walk.
- `editor.search.note`: 2,000 matches are not seeded.

`editor_find` and `editor_search` are **not** excused: their parity is in `3b-ii-search.jsonl`.
`editor.search.cancel` is not excused either, unless the measured run above shows the search
finishing before a press can land; only then does it get a line, in `editor.saving.cancel`'s
words.
- `editor.tree.loading`: a folder over the fixture loads in milliseconds.
- `editor.tree.error:<…>`: every fixture root lists.
- `editor.search.rerun`: covered by unit tests, and by the walk.

- [ ] **Step 2: Write the runbook**

`docs/wakil/phase-3b-ii-acceptance.md`, in `phase-3b-i-acceptance.md`'s shape:
- a header, with the spec and plan links and *"Not yet walked."*;
- §0 Setup;
- §1 The walk, a ten-row table;
- §2–3 Residue;
- §4, the machine walk, left for `make e2e-runbook` to render.

§0 extends the 3b-i walk's setup:

```bash
set -e
ORG=initech
cd /Users/operator/Desktop/scripts/wakil
rm -rf /tmp/walk-tree /tmp/walk-tree-project
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.name=walk -c user.email=walk@example.com"
mkdir -p /tmp/walk-tree/api /tmp/walk-tree/portal /tmp/walk-tree-project
cd /tmp/walk-tree/api && git init -q -b main
printf '.env\nvendor/\n' > .gitignore; echo 'DB_PASSWORD=walk' > .env
mkdir -p app/Models vendor/laravel && echo '<?php $bookingId = 1;' > app/Models/Booking.php && echo '<?php' > vendor/autoload.php
git add . && $G commit -qm init
cd /tmp/walk-tree/portal && git init -q -b main
mkdir -p src && echo 'const bookingId = 2;' > src/routes.ts && git add . && $G commit -qm init
cat > /tmp/walk-tree-project/project.json <<J
{"name":"walk-tree","org":"$ORG","roots":[{"path":"/tmp/walk-tree"}],"scopes":{},"environments":{}}
J
cd /Users/operator/Desktop/scripts/wakil
./bin/wakil project rm walk-tree --org "$ORG" || true
./bin/wakil project add walk-tree --path /tmp/walk-tree-project/project.json --org "$ORG"
```

The one root is a folder of two repositories, so the walk sees child-repository nodes.

| # | Do | Expect |
|---|---|---|
| 1 | ⌘T, then ⌘B; drag the column's edge right, then far right | The column shows `walk-tree` with `api` and `portal` as nodes. The edge drags, and stops at half the pane |
| 2 | Open `api` → `app` → `Models`; click `Booking.php`, then `routes.ts` under `portal` | Each opens in one italic preview tab, replaced by the next. ↑↓ moves through the tree without Monaco taking the keyboard |
| 3 | Double-click `routes.ts`'s row; type a character in it | The tab title is no longer italic. Typing also keeps a preview tab |
| 4 | Open `api`'s `.env` from the tree, then ⌘P `env` | `.env` is dimmed in both; ⌘P ranks it below any tracked `env` file. It opens |
| 5 | Open `vendor` | One dimmed row until opened; then `laravel` and `autoload.php`, dimmed |
| 6 | ⌘⇧F, type `bookingId` (no Enter) | Results after a short pause: `api` and `portal` groups. Return on `routes.ts:1` opens it at the match, with Monaco's find bar on `bookingId` |
| 7 | Switch on `.*`, type `book(` | `missing closing )` in full; nothing runs |
| 8 | In a terminal: `cd /tmp/walk-tree/api && git checkout -qb x && touch born.php` | `born.php` appears within about a second; open folders stay open. The Search view shows *files changed since this search · Re-run* |
| 9 | In a file, ⌘F `booking`, ⌥⌘F `booking_id`, replace all; Esc. Then ask the agent "find bookingId in this file" and "search the project for bookingId" | The find bar is in Wakil's colours, the tab turns dirty, and ⌘Z undoes it. The agent's find opens the bar on its query; its search fills the Search view |
| 10 | Quit (clean) and relaunch | Each pane's column is back: shown, view, width and open folders. A new ⌘T pane starts as the last one was left |

§2's residue:
- selection is view-local, so `read_pane` does not report the tree's highlighted row;
- the watcher reports roots, so *changed since* is per root;
- the 2,000 note is walk-only, and Cancel too if the measured run excused it.

- [ ] **Step 3: Docs check, the checks green, then red against main**

Run, as the controller:
1. `make docs-check`, then `make build && make app-test`.
2. Then `make e2e-new`, which writes the proofs. Commit them.
3. Then a full `make e2e`.
4. Then `make e2e-new` again at HEAD.
5. Then `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-3b-ii-acceptance.md`.

Each GUI step needs the operator's go-ahead: the GUI is shared. Never switch checkout while a gate
runs (memory `never-switch-checkout-under-a-gate`).

Expected:
- every 3b-ii check is green on the stack and red against the merge-base;
- `wakil-e2e-cover` reports no unexcused new surface;
- the runbook's machine section says green.

- [ ] **Step 4: Commit**

```bash
gh stack add yehia-khalil/3b-ii-9-docs
git add docs e2e CONTRIBUTING.md
git commit -m "Docs and e2e: Decision 37, design-language §1/§11, the 3b-ii checks and acceptance runbook (3b-ii PR 9)"
```

---

## Self-review

**Spec coverage.** Each spec section maps to a task:

| Spec | Task |
|---|---|
| Left column, views, toggle, width, persistence, new-pane default | 3, 5, 7, 8 |
| Files: roots, child repos, dimmed ignored, heavy load-on-open | 1, 3, 5, 8 |
| Files: keys | 3, 8 |
| Files: preview tab | 4, 5, 8 |
| Files: live tree | 5, 7 |
| Files: ⌘T/⌘S start at the selected folder | 8 |
| Search: query and switches, 250 ms, Enter | 4, 8 |
| Search: grouping | 4, 8 |
| Search: open at match with find | 6, 8 |
| Search: tick and Cancel | 6, 8, 9 |
| Search: 2,000 note | 2, 8 |
| Search: invalid regex | 2, 6, 8 |
| Search: changed since | 6, 7, 8 |
| Find in file (Monaco bar, colours, Esc) | 6, 8 |
| ⌘P ignored, dimmed, ranked last | 7, 8 |
| Six actions + `read_pane` fields | 4, 5, 6 |
| Errors and edges table | 1, 3, 5, 6, 8 |
| Testing (Go / WakilKit / e2e / walk) | 1–9 |
| Charter changes (design-language §1/§11, Decision 37, 3b-i pointer) | 9 |

**Spec gaps and conflicts, with their rulings:**
- `repos` added to `files_list` (Task 1).
- Outside a repository, the walk's skipped folders are heavy too (Task 1).
- `--exclude` replaced by pathspec excludes (Task 1).
- Go `regexp` over the listed files instead of `git grep` (Task 2), for one pattern semantics and
  Go's own error text.
- Search Cancel is `editor_search {cancel: true}`, keeping six actions (Task 6).
- "Changed since" is per root (Task 6).
- The tree's selection is view-local, not in `read_pane`. It is the residue in Task 9's runbook.
- **Pre-flight ruling, finding 17 (2026-10-13).** The spec's e2e Testing list is kept, not
  excused: Task 9 drives `editor_search` parity (the whole-word switch) and `editor_find` parity (a
  click on a search result) in `3b-ii-search.jsonl`, and "Cancel stops a search" in
  `3b-ii-search-cancel.jsonl` against a committed `bulk/` haystack. Cancel is excused in
  `uncoverable.tsv` only if a measured run shows the search finishing before a press can land,
  on `editor.saving.cancel`'s precedent; the unit test `cancelStopsTheSearchInFlight` pins that the
  tool call itself stops either way.

**Pre-flight corrections (2026-10-13).** The scan in
`.superpowers/sdd/2026-10-13-3b-ii-editor-tree/progress.md` found 18 items. Findings 1–5, 7–16
and 18 are corrected in their owning tasks above. Finding 6 (walk-skipped folders heavy, `vendor`
skipped, Go `regexp` instead of `git grep`) stands as written, with the operator's go-ahead.
Finding 17 is the ruling above.

**Type consistency.** These names are used identically across Tasks 3–8:
- `EditorColumnState`, `EditorColumnView`, `EditorRootListing`, `EditorDirEntry`, `EditorTreeRow`;
- `EditorSearchState`, `EditorSearchMatch`, `EditorFindRequest`, `EditorFindReport`;
- `EditorFileLists`, `EditorFileListsState`, `editorFiles`, `toggleEditorColumn`;
- `editorFindDidReport`, `isDimmed`.
