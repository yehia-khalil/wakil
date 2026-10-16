# 3b-i: the editor core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `editor` pane kind: files from ⌘P open as tabs in Monaco, ⌘T opens a scratch tab, ⌘S
saves through a new roots-confined Go capability, and the agent drives it through the same actions.

**Architecture:** `cmd/wakil-files` (Go, window-owned MCP binary) lists, reads and writes files inside
the active project's roots. `WakilKit/Editor/` holds the pane kind, its store methods, its actions and
the pure rules; the store owns each tab's text and Monaco mirrors it through an `EditorRenderer` seam.
`WakilApp` draws the pane and hosts Monaco in an editor mode of the 3a-i host page.

**Tech Stack:** Go 1.x + `modelcontextprotocol/go-sdk` (fork); Swift 6.4 (language mode 6), Swift
Testing, Observation, WebKit; Monaco 0.52.2 (bundled under `app/Sources/WakilApp/monaco/`).

**Spec:** `docs/superpowers/specs/2026-10-11-3b-i-editor-core-design.md`

## Global Constraints

- File write is allowed **only inside the active project's roots**, after resolving symlinks and `..`.
  A refusal names *Invariant 6* and *Decision 36*.
- `editor_save`'s price is `(production: .allow, otherwise: .allow)`; every editor action is
  `.agentReachable`.
- Text cap: **2 MB** (`2 * 1024 * 1024` bytes). List cap: **50,000** entries. UTF-8 only.
- Line endings are kept as the file had them; nothing normalises them.
- The operator's typing reaches the store through **one** non-action path,
  `PaneStore.editorBufferDidChange`. Nothing else may call it.
- Unsaved edits and scratch contents are never persisted.
- Interaction Rules (`PRODUCT.md`): ⌘S has no dialog; only destroying unsaved work asks; a new input
  arrives focused; a save in flight shows and cannot double-fire; errors are whole.
- Commits: no `Co-Authored-By` or "Generated with Claude Code" lines (operator rule).
- Stacked PRs with gh-stack; one task = one layer. Branches `yehia-khalil/3b-i-<n>-<slug>`.
- Test commands. Go: `go test ./internal/wakilcore/ -run <Name>` and `go test ./cmd/wakil-files/`.
  Swift, filtered: `cd app && ../scripts/swift-test.sh --filter '<regex>'`. Swift, full:
  `make build && make app-test` (controller only, never a subagent — `make app-test` does not build Go).
  Docs: `make docs-check`.
- Under the Swift 6.4 toolchain, `map`/`flatMap`/key paths over `[any PaneKind.Type]` crash SILGen:
  write plain loops (CONTRIBUTING.md, "Two traps").

## Review Focus

1. **A symlink inside a root pointing outside it** — read and write must refuse it, as must a path whose
   parent folder is such a link and does not exist yet (create). Pinned in Task 1:
   `TestFilesConfineRefusesALinkOutOfTheRoot`, `TestFilesWriteCreateRefusesAParentLinkOutOfTheRoot`.
2. **The agent edits a buffer the operator is typing in** — the agent's `editor_replace_range` lands
   on the store's current text, not a stale copy, and the view applies it without resetting the
   operator's cursor. Pinned in Task 4: `replaceRangeAppliesToTheTextAsTypedSoFar`; Task 7:
   `renderUpdateForAnAgentEditIsAnEditNotAReset`.
3. **A save that lands after the operator kept typing** — the buffer must stay dirty (the disk holds
   the older text). Pinned in Task 4: `aSaveThatLandsAfterMoreTypingLeavesTheTabDirty`.
4. **The disk changes back to exactly the buffer's text** (e.g. the agent writes what the operator
   typed) — the tab is clean and in sync, not "changed on disk". Pinned in Task 5:
   `aDiskChangeMatchingTheBufferMarksTheTabClean`.
5. **Two tabs with the same file name in different roots** — titles disambiguate with the parent
   folder, and `editor_open` of one never focuses the other. Pinned in Task 3:
   `titlesOfTwoSameNamedFilesNameTheirFolders`; Task 4: `openingASameNamedFileInAnotherRootOpensANewTab`.

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `internal/wakilcore/files.go`, `files_test.go` | 1 | confinement, list, read, write |
| `cmd/wakil-files/main.go`, `main_test.go`, `schema_test.go` | 1 | the MCP binary |
| `Makefile`, `scripts/make-app-bundle.sh`, `scripts/app_bundle_test.go`, `.gitignore`, `docs/architecture/go.md` | 1 | binary registration |
| `app/Sources/WakilKit/Panes/PaneKind.swift`, `App/WindowModel.swift` (`restorePaneContents`), `Git/GitPaneKind.swift`, `Panes/DataSurfacePaneKind.swift` | 2 | `PaneRestoreStep` hook |
| `app/Sources/WakilKit/Editor/EditorSnapshot.swift` | 3 | tab and pane value types |
| `app/Sources/WakilKit/Editor/EditorPaneKind.swift` | 3 | conformance, `read_pane` |
| `app/Sources/WakilKit/Editor/PaneStore+Editor.swift` | 3 | store methods, `editorBufferDidChange` |
| `app/Sources/WakilKit/Editor/EditorTabs.swift` | 3 | pure rules: titles, ⌘W, scratch numbers, language by extension, saved tabs |
| `app/Sources/WakilKit/Layout/Pane.swift`, `Layout/LayoutStore.swift` | 3 | `Pane.editorTabs` persisted, `setEditorTabs` |
| `app/Sources/WakilKit/App/PaneKinds.swift` | 3 | registration |
| `app/Sources/WakilKit/Editor/EditorActions.swift` | 4, 5 | the editor actions, `editor_restore`, `editor_refresh` |
| `app/Sources/WakilKit/App/AppWiring.swift` | 4 | start `wakil-files`, register actions |
| `app/Sources/WakilKit/App/WindowModel.swift` | 5, 6, 8, 9 | editor watcher, palette source, ⌘T/⌘S/⌘W, unsaved prompt |
| `app/Sources/WakilKit/Command/PaletteSources.swift`, `Command/PaletteEntry.swift` | 6 | `FilesSource`, `.openInEditor` |
| `app/Sources/WakilKit/Editor/EditorRenderer.swift` | 7 | the seam and the render decision |
| `app/Sources/WakilApp/monaco-host.html`, `MonacoEditorRenderer.swift`, `EditorPane.swift`, `Canvas.swift`, `AppScene.swift` | 8 | drawing, menu commands |
| `docs/wakil/decisions.md`, `north-star.md`, `design-language.md`, `open-questions.md`, `docs/architecture/wakilkit.md`, `CONTRIBUTING.md`, `docs/wakil/phase-3b-i-acceptance.md` | 10 | charter and docs |

Test files: `app/Tests/WakilKitTests/Editor*Tests.swift`, `EditorTestSupport.swift` (FakeFiles).

---

### Task 1: `wakil-files` — a roots-confined file capability (PR 1)

**Files:**
- Create: `internal/wakilcore/files.go`, `internal/wakilcore/files_test.go`
- Create: `cmd/wakil-files/main.go`, `cmd/wakil-files/main_test.go`, `cmd/wakil-files/schema_test.go`
- Modify: `Makefile` (`BINS`), `scripts/make-app-bundle.sh:63`, `scripts/app_bundle_test.go:36`, `.gitignore`, `docs/architecture/go.md` (new `### wakil-files`)

**Interfaces:**
- Produces (Go): `wakilcore.FileCap = 2 << 20`, `wakilcore.FileListCap = 50000`,
  `ConfineFilePath(path string, roots []string, mustExist bool) (real string, root string, err error)`,
  `ListFiles(ctx, root string, roots []string) (FileList, error)`,
  `ReadFile(path string, roots []string) (FileRead, error)`,
  `WriteFile(path, text string, create bool, roots []string) (FileWritten, error)`.
- Produces (MCP): tools `files_list {root}` → `{root, files: [string], truncated}`;
  `files_read {path}` → `{path, root, text, size, mtime, binary, utf8, over_cap, exists}`;
  `files_write {path, text, create}` → `{path, size, mtime}`. `mtime` is Unix nanoseconds (int64).

- [ ] **Step 1: Write the failing confinement and I/O tests**

`internal/wakilcore/files_test.go`:

```go
package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// filesRoots makes two roots under one temp dir and an outside dir, symlink-resolved.
func filesRoots(t *testing.T) (a, b, outside string) {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	a, b, outside = filepath.Join(base, "a"), filepath.Join(base, "b"), filepath.Join(base, "out")
	for _, d := range []string{a, b, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestFilesConfineAcceptsAFileInARoot(t *testing.T) {
	a, b, _ := filesRoots(t)
	write(t, filepath.Join(b, "x.go"), "x")
	real, root, err := ConfineFilePath(filepath.Join(b, "x.go"), []string{a, b}, true)
	if err != nil || real != filepath.Join(b, "x.go") || root != b {
		t.Fatalf("got %q %q %v", real, root, err)
	}
}

func TestFilesConfineRefusesDotDotOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "s.txt"), "secret")
	_, _, err := ConfineFilePath(filepath.Join(a, "..", "out", "s.txt"), []string{a}, true)
	if err == nil || !strings.Contains(err.Error(), "Invariant 6") || !strings.Contains(err.Error(), "Decision 36") {
		t.Fatalf("want a refusal naming Invariant 6 and Decision 36, got %v", err)
	}
}

func TestFilesConfineRefusesALinkOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "s.txt"), "secret")
	if err := os.Symlink(filepath.Join(outside, "s.txt"), filepath.Join(a, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ConfineFilePath(filepath.Join(a, "link.txt"), []string{a}, true); err == nil {
		t.Fatal("a link out of the root was accepted")
	}
}

func TestFilesConfineRefusesARelativePath(t *testing.T) {
	a, _, _ := filesRoots(t)
	if _, _, err := ConfineFilePath("x.go", []string{a}, false); err == nil {
		t.Fatal("a relative path was accepted")
	}
}

func TestFilesReadReturnsTextSizeAndMtime(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "m.go"), "line1\r\nline2\r\n")
	r, err := ReadFile(filepath.Join(a, "m.go"), []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if r.Text != "line1\r\nline2\r\n" || r.Size != 14 || r.Mtime == 0 || !r.UTF8 || r.Binary || !r.Exists {
		t.Fatalf("got %+v", r)
	}
}

func TestFilesReadOverTheCapReturnsNoText(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "big.sql"), strings.Repeat("x", FileCap+1))
	r, err := ReadFile(filepath.Join(a, "big.sql"), []string{a})
	if err != nil || r.Text != "" || !r.OverCap || r.Size != FileCap+1 {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesReadBinaryAndNonUTF8(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "b.bin"), "ab\x00cd")
	write(t, filepath.Join(a, "l.txt"), "caf\xe9")
	bin, _ := ReadFile(filepath.Join(a, "b.bin"), []string{a})
	lat, _ := ReadFile(filepath.Join(a, "l.txt"), []string{a})
	if !bin.Binary || bin.Text != "" {
		t.Fatalf("binary: %+v", bin)
	}
	if lat.UTF8 || lat.Text != "" || lat.Binary {
		t.Fatalf("latin-1: %+v", lat)
	}
}

func TestFilesReadOfAMissingFileSaysItDoesNotExist(t *testing.T) {
	a, _, _ := filesRoots(t)
	r, err := ReadFile(filepath.Join(a, "gone.go"), []string{a})
	if err != nil || r.Exists {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesWriteRoundTripsAndKeepsLineEndings(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "w.go")
	write(t, p, "old")
	w, err := WriteFile(p, "new\r\n", false, []string{a})
	if err != nil || w.Size != 5 || w.Mtime == 0 {
		t.Fatalf("got %+v %v", w, err)
	}
	got, _ := os.ReadFile(p)
	if string(got) != "new\r\n" {
		t.Fatalf("disk has %q", got)
	}
}

func TestFilesWriteWithoutCreateRefusesAMissingFile(t *testing.T) {
	a, _, _ := filesRoots(t)
	if _, err := WriteFile(filepath.Join(a, "nope.go"), "x", false, []string{a}); err == nil {
		t.Fatal("wrote a missing file without create")
	}
}

func TestFilesWriteCreateMakesParentFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "new", "dir", "f.sql")
	if _, err := WriteFile(p, "select 1", true, []string{a}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(p); string(got) != "select 1" {
		t.Fatalf("disk has %q", got)
	}
}

func TestFilesWriteCreateRefusesAParentLinkOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	if err := os.Symlink(outside, filepath.Join(a, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteFile(filepath.Join(a, "escape", "sub", "f.txt"), "x", true, []string{a}); err == nil {
		t.Fatal("created through a link out of the root")
	}
	if _, err := os.Stat(filepath.Join(outside, "sub")); err == nil {
		t.Fatal("a folder was made outside the root")
	}
}

func TestFilesWriteLeavesNoTempFileBehind(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "t.go")
	write(t, p, "x")
	if _, err := WriteFile(p, "y", false, []string{a}); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(a)
	if len(entries) != 1 {
		t.Fatalf("folder holds %d entries, want 1", len(entries))
	}
}

func TestFilesListInARepoRespectsGitignore(t *testing.T) {
	a, _, _ := filesRoots(t)
	run := func(args ...string) {
		c := exec.Command("git", args...)
		c.Dir = a
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-b", "main")
	write(t, filepath.Join(a, ".gitignore"), "vendor/\n")
	write(t, filepath.Join(a, "src", "k.go"), "k")
	write(t, filepath.Join(a, "vendor", "v.go"), "v")
	l, err := ListFiles(context.Background(), a, []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(l.Files, ",") != ".gitignore,src/k.go" || l.Truncated {
		t.Fatalf("got %v", l.Files)
	}
}

func TestFilesListOutsideARepoWalksAndSkipsDotGit(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "one.txt"), "1")
	write(t, filepath.Join(a, "d", "two.txt"), "2")
	write(t, filepath.Join(a, ".git", "HEAD"), "ref")
	l, err := ListFiles(context.Background(), a, []string{a})
	if err != nil || strings.Join(l.Files, ",") != "d/two.txt,one.txt" {
		t.Fatalf("got %v %v", l.Files, err)
	}
}

func TestFilesListRefusesARootThatIsNotTheProjects(t *testing.T) {
	a, b, _ := filesRoots(t)
	if _, err := ListFiles(context.Background(), b, []string{a}); err == nil {
		t.Fatal("listed a root the project does not declare")
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run TestFiles`
Expected: FAIL — `undefined: ConfineFilePath` (and the others).

- [ ] **Step 3: Implement `files.go`**

```go
package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

// FileCap is the most text files_read returns (spec 3b-i: larger files are 3b-v's).
const FileCap = 2 << 20

// FileListCap is the most entries files_list returns for one root.
const FileListCap = 50000

// FileList is one root's files, relative and slash-separated, sorted.
type FileList struct {
	Root      string   `json:"root"`
	Files     []string `json:"files"`
	Truncated bool     `json:"truncated"`
}

// FileRead is one file's text and facts. Text is empty when the file is over the cap,
// binary, not UTF-8, or missing; the flags say which.
type FileRead struct {
	Path    string `json:"path"`
	Root    string `json:"root"`
	Text    string `json:"text"`
	Size    int    `json:"size"`
	Mtime   int64  `json:"mtime"`
	Binary  bool   `json:"binary"`
	UTF8    bool   `json:"utf8"`
	OverCap bool   `json:"over_cap"`
	Exists  bool   `json:"exists"`
}

// FileWritten is what a write left on disk.
type FileWritten struct {
	Path  string `json:"path"`
	Size  int    `json:"size"`
	Mtime int64  `json:"mtime"`
}

func outsideRoots(path string) error {
	return UserError(path + " is outside the active project's roots; editor writes and reads are " +
		"confined to them (Invariant 6, Decision 36)")
}

// realRoots answers each root symlink-resolved; a root that cannot be resolved is skipped.
func realRoots(roots []string) []string {
	var out []string
	for _, r := range roots {
		if rr, err := filepath.EvalSymlinks(r); err == nil {
			out = append(out, rr)
		}
	}
	return out
}

func under(path, root string) bool {
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}

// ConfineFilePath resolves path (absolute) through symlinks and answers it with the root
// holding it. A path that does not exist yet (mustExist false) is resolved through its
// nearest existing ancestor, so a link anywhere above it is followed before the check.
func ConfineFilePath(path string, roots []string, mustExist bool) (string, string, error) {
	if !filepath.IsAbs(path) {
		return "", "", UserError("path must be absolute, got " + path)
	}
	clean := filepath.Clean(path)
	real, err := filepath.EvalSymlinks(clean)
	if err != nil {
		if mustExist || !errors.Is(err, fs.ErrNotExist) {
			return "", "", UserError(path + " is not readable: " + err.Error())
		}
		// Walk up to the nearest ancestor that exists, resolve it, and re-attach the rest.
		rest := []string{filepath.Base(clean)}
		dir := filepath.Dir(clean)
		for {
			if r, e := filepath.EvalSymlinks(dir); e == nil {
				real = filepath.Join(append([]string{r}, rest...)...)
				break
			} else if !errors.Is(e, fs.ErrNotExist) || dir == filepath.Dir(dir) {
				return "", "", UserError(path + " is not reachable: " + e.Error())
			}
			rest = append([]string{filepath.Base(dir)}, rest...)
			dir = filepath.Dir(dir)
		}
	}
	for _, r := range realRoots(roots) {
		if under(real, r) {
			return real, r, nil
		}
	}
	return "", "", outsideRoots(path)
}

// ListFiles lists one root: git's view (tracked plus untracked, ignores applied) in a repo,
// a walk skipping .git otherwise.
func ListFiles(ctx context.Context, root string, roots []string) (FileList, error) {
	real, err := filepath.EvalSymlinks(root)
	if err != nil {
		return FileList{}, UserError("root " + root + " is not readable: " + err.Error())
	}
	ok := false
	for _, r := range realRoots(roots) {
		if r == real {
			ok = true
		}
	}
	if !ok {
		return FileList{}, UserError("root " + root + " is not a root of the active project")
	}
	var files []string
	cmd := exec.CommandContext(ctx, "git", append(append([]string{}, gitSafetyArgs...),
		"ls-files", "-z", "--cached", "--others", "--exclude-standard")...)
	cmd.Dir = real
	if out, gerr := cmd.Output(); gerr == nil {
		for _, f := range bytes.Split(out, []byte{0}) {
			if len(f) > 0 {
				files = append(files, string(f))
			}
		}
	} else {
		werr := filepath.WalkDir(real, func(p string, d fs.DirEntry, e error) error {
			if e != nil {
				return nil
			}
			if d.IsDir() && d.Name() == ".git" {
				return filepath.SkipDir
			}
			if !d.IsDir() {
				rel, _ := filepath.Rel(real, p)
				files = append(files, filepath.ToSlash(rel))
			}
			return nil
		})
		if werr != nil {
			return FileList{}, werr
		}
	}
	sort.Strings(files)
	truncated := len(files) > FileListCap
	if truncated {
		files = files[:FileListCap]
	}
	if files == nil {
		files = []string{}
	}
	return FileList{Root: real, Files: files, Truncated: truncated}, nil
}

// ReadFile reads one file inside the roots.
func ReadFile(path string, roots []string) (FileRead, error) {
	real, root, err := ConfineFilePath(path, roots, false)
	if err != nil {
		return FileRead{}, err
	}
	info, err := os.Stat(real)
	if errors.Is(err, fs.ErrNotExist) {
		return FileRead{Path: real, Root: root, UTF8: true}, nil
	}
	if err != nil {
		return FileRead{}, err
	}
	if info.IsDir() {
		return FileRead{}, UserError(path + " is a folder, not a file")
	}
	r := FileRead{Path: real, Root: root, Size: int(info.Size()), Mtime: info.ModTime().UnixNano(), Exists: true}
	if r.Size > FileCap {
		r.OverCap = true
		r.UTF8 = true
		return r, nil
	}
	data, err := os.ReadFile(real)
	if err != nil {
		return FileRead{}, err
	}
	switch {
	case bytes.IndexByte(data, 0) >= 0:
		r.Binary = true
	case !utf8.Valid(data):
		r.UTF8 = false
	default:
		r.UTF8 = true
		r.Text = string(data)
	}
	return r, nil
}

// WriteFile writes text to a file inside the roots: to a temporary file in the same folder,
// then renamed into place, so a failed write never leaves half a file.
func WriteFile(path, text string, create bool, roots []string) (FileWritten, error) {
	real, _, err := ConfineFilePath(path, roots, false)
	if err != nil {
		return FileWritten{}, err
	}
	mode := fs.FileMode(0o644)
	if info, serr := os.Stat(real); serr == nil {
		if info.IsDir() {
			return FileWritten{}, UserError(path + " is a folder, not a file")
		}
		mode = info.Mode().Perm()
	} else if errors.Is(serr, fs.ErrNotExist) {
		if !create {
			return FileWritten{}, UserError(path + " does not exist; save it as a new file to create it")
		}
		if err := os.MkdirAll(filepath.Dir(real), 0o755); err != nil {
			return FileWritten{}, err
		}
	} else {
		return FileWritten{}, serr
	}
	tmp, err := os.CreateTemp(filepath.Dir(real), "."+filepath.Base(real)+".wakil-*")
	if err != nil {
		return FileWritten{}, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return FileWritten{}, err
	}
	if err := tmp.Close(); err != nil {
		return FileWritten{}, err
	}
	if err := os.Chmod(tmp.Name(), mode); err != nil {
		return FileWritten{}, err
	}
	if err := os.Rename(tmp.Name(), real); err != nil {
		return FileWritten{}, err
	}
	info, err := os.Stat(real)
	if err != nil {
		return FileWritten{}, err
	}
	return FileWritten{Path: real, Size: int(info.Size()), Mtime: info.ModTime().UnixNano()}, nil
}
```

- [ ] **Step 4: Run the core tests**

Run: `go test ./internal/wakilcore/ -run TestFiles -v`
Expected: PASS (all 15).

- [ ] **Step 5: Write the binary's failing tests**

`cmd/wakil-files/main_test.go` — copy `setupProject` from `cmd/wakil-git/main_test.go` verbatim
(the helper is per-package), then:

```go
func callFiles(t *testing.T, tool string, args map[string]any) (*mcp.CallToolResult, map[string]any) {
	t.Helper()
	ctx := context.Background()
	st, ct := mcp.NewInMemoryTransports()
	if _, err := newServer().Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "t"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if res.StructuredContent != nil {
		b, _ := json.Marshal(res.StructuredContent)
		_ = json.Unmarshal(b, &out)
	}
	return res, out
}

func TestFilesWriteThenReadThroughTheServer(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "src", "a.go")
	if res, _ := callFiles(t, "files_write", map[string]any{"path": p, "text": "package a\n", "create": true}); res.IsError {
		t.Fatalf("write failed: %+v", res.Content)
	}
	_, out := callFiles(t, "files_read", map[string]any{"path": p})
	if out["text"] != "package a\n" || out["exists"] != true {
		t.Fatalf("read %v", out)
	}
	_, list := callFiles(t, "files_list", map[string]any{"root": pdir})
	if !slices.Contains(toStrings(list["files"]), "src/a.go") {
		t.Fatalf("list %v", list)
	}
}

func TestFilesRefusesAPathOutsideTheProject(t *testing.T) {
	setupProject(t, `"dev":{"databases":[]}`, "")
	res, _ := callFiles(t, "files_read", map[string]any{"path": "/etc/hosts"})
	if !res.IsError {
		t.Fatal("read outside the project was allowed")
	}
	text := res.Content[0].(*mcp.TextContent).Text
	if !strings.Contains(text, "Invariant 6") {
		t.Fatalf("refusal does not name the invariant: %s", text)
	}
}

func toStrings(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}
```

`cmd/wakil-files/schema_test.go`:

```go
package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{"files_list", "files_read", "files_write"})
}
```

Run: `go test ./cmd/wakil-files/`
Expected: FAIL — package has no `newServer`.

- [ ] **Step 6: Implement `cmd/wakil-files/main.go`**

```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type listArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
}
type readArg struct {
	Path string `json:"path" jsonschema:"absolute path of a file inside one of the active project's roots"`
}
type writeArg struct {
	Path   string `json:"path" jsonschema:"absolute path of a file inside one of the active project's roots"`
	Text   string `json:"text" jsonschema:"the whole new contents, written as given (line endings kept)"`
	Create bool   `json:"create" jsonschema:"true to create the file (and missing folders inside the root) if absent"`
}

// roots answers the active project's roots, or the tool error saying why there are none.
func roots() ([]string, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-files", err)
	}
	return wakilcore.ProjectRootPaths(*r), nil
}

func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-files", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "files_list", Description: "Read-only. One root's files, relative and sorted: git's tracked and untracked files with ignores applied in a repository, every file but .git's otherwise. Capped at 50,000; truncated says so."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a listArg) (*mcp.CallToolResult, wakilcore.FileList, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileList{}, nil
			}
			l, err := wakilcore.ListFiles(ctx, a.Root, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileList{}, nil
			}
			return nil, l, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_read", Description: "Read-only. One file's text, size and mtime (Unix ns). No text over 2 MB (over_cap), for a binary file (binary) or a file that is not UTF-8 (utf8 false); exists false for a missing file. Confined to the active project's roots."},
		func(_ context.Context, _ *mcp.CallToolRequest, a readArg) (*mcp.CallToolResult, wakilcore.FileRead, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileRead{}, nil
			}
			r, err := wakilcore.ReadFile(a.Path, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileRead{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_write", Description: "Writes one file's whole text, atomically. create false refuses a missing file. Confined to the active project's roots (Invariant 6, Decision 36); delete and rename are not offered."},
		func(_ context.Context, _ *mcp.CallToolRequest, a writeArg) (*mcp.CallToolResult, wakilcore.FileWritten, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileWritten{}, nil
			}
			w, err := wakilcore.WriteFile(a.Path, a.Text, a.Create, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileWritten{}, nil
			}
			return nil, w, nil
		})
	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

Check `cmd/wakil-git/main.go`'s `main()` and copy its exact form if it differs from the above.

- [ ] **Step 7: Register the binary** (CONTRIBUTING.md, "A new MCP binary", steps 2–4 and 7)

- `Makefile`: `BINS := wakil wakil-ctx wakil-db wakil-git wakil-http wakil-pm wakil-recall wakil-files`
- `scripts/make-app-bundle.sh:63`: add `wakil-files` to the `for b in …` list.
- `scripts/app_bundle_test.go:36`: add `"wakil-files"` to `bundledServers`.
- `.gitignore`: add `/wakil-files` beside `/wakil-git`.
- `docs/architecture/go.md`, after `### wakil-git`:

```markdown
### wakil-files

The editor's file capability (3b-i). `files_list` (one root's files: `git ls-files` with ignores
in a repository, a walk otherwise; capped at 50,000), `files_read` (text up to 2 MB, size, mtime;
no text for binary or non-UTF-8 files) and `files_write` (whole text, atomic rename, `create` for a
new file). Every path is confined to the active project's roots after resolving symlinks
(`wakilcore.ConfineFilePath`); a refusal names Invariant 6 and Decision 36. Window-owned: started in
`WakilWiring.build` and joined to the org switch. Not registered into providers — the agent has its
own file tools. Logic in `internal/wakilcore/files.go`.
```

- [ ] **Step 8: Run everything Go and the docs check**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-files/ ./scripts/ && make docs-check && make build`
Expected: PASS; `built: … wakil-files`.

- [ ] **Step 9: Commit**

```bash
git add internal/wakilcore/files.go internal/wakilcore/files_test.go cmd/wakil-files Makefile \
  scripts/make-app-bundle.sh scripts/app_bundle_test.go .gitignore docs/architecture/go.md
git commit -m "wakil-files: list, read and write files confined to the project's roots (3b-i PR 1)"
```

---

### Task 2: A per-kind restore step (PR 2)

No behaviour change: git and db panes restore exactly as today, but `restorePaneContents` stops
naming kinds. Deferred to the editor by the pane-kinds work.

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneKind.swift`
- Modify: `app/Sources/WakilKit/Git/GitPaneKind.swift`, `app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`restorePaneContents`)
- Modify: `CONTRIBUTING.md` ("A new pane kind": replace the restore paragraph)
- Test: `app/Tests/WakilKitTests/PaneKindRestoreTests.swift`

**Interfaces:**
- Produces: `public struct PaneRestoreStep: Sendable, Equatable { action: String; params: JSONValue; recordsFailure: Bool }`
  and `static func restoreStep(for pane: Pane) -> PaneRestoreStep?` on `PaneKind` (default `nil`).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func gitRestoresByRefreshingAndRecordsNoFailure() {
    let pane = Pane(id: "g", kind: "git", title: "Git", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    #expect(GitPaneKind.restoreStep(for: pane)
        == PaneRestoreStep(action: "git_refresh", params: .object(["pane": .string("g")]), recordsFailure: false))
}

@Test func aDbPaneRestoresByRefetchingOnlyWhenItHasAFetch() {
    let frame = PaneFrame(x: 0, y: 0, width: 1, height: 1)
    let bare = Pane(id: "d", kind: "db", title: "db", frame: frame)
    #expect(DataSurfacePaneKind.restoreStep(for: bare) == nil)
    let fetched = Pane(id: "d", kind: "db", title: "db", frame: frame,
                       fetch: .query(sql: "select 1", database: nil))
    #expect(DataSurfacePaneKind.restoreStep(for: fetched)
        == PaneRestoreStep(action: "db_refetch", params: .object(["pane": .string("d")]), recordsFailure: true))
}

@Test func kindsWhoseSubjectIsNotARerunRestoreNothing() {
    let frame = PaneFrame(x: 0, y: 0, width: 1, height: 1)
    #expect(TerminalPaneKind.restoreStep(for: Pane(id: "t", kind: "terminal", title: "t", frame: frame)) == nil)
    #expect(ApiPaneKind.restoreStep(for: Pane(id: "a", kind: "api", title: "a", frame: frame)) == nil)
}
```

Before writing the db test, read `Layout/PaneFetch.swift` for the real `PaneFetch` case to construct
(use whatever case `db_query` stores); keep the assertion shape.

Run: `cd app && ../scripts/swift-test.sh --filter 'PaneKindRestore|gitRestores|aDbPaneRestores|kindsWhoseSubject'`
Expected: FAIL — `PaneRestoreStep` not found.

- [ ] **Step 2: Add the hook to `PaneKind.swift`**

Inside `protocol PaneKind`, after `rerunsSubjectOnRestore`:

```swift
    /// The action a restored pane of this kind dispatches (launch, an org switch loaded from disk),
    /// or nil for none. `recordsFailure` writes a refusal into the pane (`setFailure`), as a db
    /// pane's refetch always has; a git pane's errors land root by root instead.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep?
```

In the `extension PaneKind` defaults: `public static func restoreStep(for pane: Pane) -> PaneRestoreStep? { nil }`.

After the protocol:

```swift
/// What `WindowModel.restorePaneContents` dispatches for one restored pane.
public struct PaneRestoreStep: Sendable, Equatable {
    public var action: String
    public var params: JSONValue
    public var recordsFailure: Bool

    public init(action: String, params: JSONValue, recordsFailure: Bool) {
        self.action = action
        self.params = params
        self.recordsFailure = recordsFailure
    }
}
```

- [ ] **Step 3: Conform git and db**

`GitPaneKind`:

```swift
    /// **A git pane's subject is the project's roots, not a fetch** (3a-i, R6): re-read by its own
    /// action, or a restored pane would list nothing until the first file changed.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        PaneRestoreStep(action: "git_refresh", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
```

`DataSurfacePaneKind` (only if `rerunsSubjectOnRestore` is true there; check):

```swift
    /// D12: a refetch that failed must not leave the pane looking empty, so its refusal is recorded.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        guard pane.fetch != nil else { return nil }
        return PaneRestoreStep(action: "db_refetch", params: .object(["pane": .string(pane.id)]), recordsFailure: true)
    }
```

- [ ] **Step 4: Replace the loop in `WindowModel.restorePaneContents`**

Replace the `for pane in layoutSnapshot.panes where … rerunsSubjectOnRestore == true { … }` loop
(keep the long comment above it, trimmed to its first paragraph plus one line: *"Each kind names its
own step (`PaneKind.restoreStep`); the loop names none."*) with:

```swift
        for pane in layoutSnapshot.panes {
            guard let kind = PaneKinds.kind(named: pane.kind), let step = kind.restoreStep(for: pane) else { continue }
            if await dispatch(step.action, step.params) == nil, step.recordsFailure {
                await panes.setFailure(paneId: pane.id, message: status)
            }
        }
```

- [ ] **Step 5: Run the restore-related suites**

Run: `cd app && ../scripts/swift-test.sh --filter 'PaneKindRestore|PaneKindClassification|WindowModelGit|Restore'`
Expected: PASS. If a `PaneKindClassificationTests` pin names the restore loop's shape, update the pin to
the new step and say so in the commit message.

- [ ] **Step 6: Update CONTRIBUTING.md**

In "A new pane kind", replace from *"Leave `rerunsSubjectOnRestore` false unless…"* to *"…A per-kind
restore hook is deferred to the editor."* with:

```markdown
A pane that must do something when it is restored (launch, an org switch loaded from disk) returns a
`PaneRestoreStep` from `restoreStep(for:)`: the action to dispatch, and whether a refusal is written
into the pane. `WindowModel.restorePaneContents` names no kind. Keep `rerunsSubjectOnRestore` true only
for a kind whose subject is a read (it is pinned in `PaneKindClassificationTests`).
```

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneKind.swift app/Sources/WakilKit/Git/GitPaneKind.swift \
  app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift app/Sources/WakilKit/App/WindowModel.swift \
  app/Tests/WakilKitTests/PaneKindRestoreTests.swift CONTRIBUTING.md
git commit -m "PaneKind.restoreStep: restorePaneContents names no kind (3b-i PR 2)"
```

---

### Task 3: The editor pane kind, its store and its saved tabs (PR 3)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorSnapshot.swift`, `EditorPaneKind.swift`, `PaneStore+Editor.swift`, `EditorTabs.swift`
- Modify: `app/Sources/WakilKit/App/PaneKinds.swift`, `app/Sources/WakilKit/Layout/Pane.swift`, `app/Sources/WakilKit/Layout/LayoutStore.swift`, `app/Sources/WakilKit/App/WindowModel.swift` (`editor(_:)` cell read), `docs/architecture/wakilkit.md` (`### Editor/`)
- Test: `app/Tests/WakilKitTests/EditorStoreTests.swift`, `EditorTabsTests.swift`, `EditorReadPaneTests.swift`

**Interfaces:**
- Produces (value types, all `public`, `Sendable, Equatable`):

```swift
public enum EditorTabSubject: Sendable, Equatable, Hashable {
    case file(path: String, root: String)
    case scratch(number: Int)
}
public enum EditorDiskState: String, Sendable, Equatable { case inSync, changedOnDisk, deleted }
public struct EditorPosition: Sendable, Equatable, Codable { public var line: Int; public var column: Int }  // 1-based
public struct EditorRange: Sendable, Equatable, Codable { public var start: EditorPosition; public var end: EditorPosition }
public struct EditorTab: Sendable, Equatable {
    public var subject: EditorTabSubject
    public var text: String
    public var savedText: String          // last read or written; dirty == text != savedText
    public var language: String
    public var diskState: EditorDiskState
    public var mtime: Int64
    public var cursor: EditorPosition
    public var selection: EditorRange?
    public var visibleRange: ClosedRange<Int>?   // 1-based lines
    public var scrollTop: Double
    public var notice: String?            // over cap, binary, not UTF-8, write failure — whole text
    public var readOnly: Bool             // over cap, binary, not UTF-8
    public var saving: Bool
    public var edits: Int                 // bumps on every text change; the renderer's edit counter
    public var lastAgentEdit: EditorAgentEdit?
    public var dirty: Bool { text != savedText }
}
public struct EditorAgentEdit: Sendable, Equatable { public var serial: Int; public var range: EditorRange; public var text: String }
public struct EditorSnapshot: Sendable, Equatable {
    public var tabs: [EditorTab]
    public var active: Int?
    public static let empty = EditorSnapshot(tabs: [], active: nil)
}
public struct EditorSavedTab: Sendable, Equatable, Codable { public var path: String; public var cursor: EditorPosition; public var scrollTop: Double }
```

- Produces (store, on `PaneStore`): `editorSnapshot(paneId:) -> EditorSnapshot`,
  `updateEditor<T>(paneId:create:_:) -> T` (same contract as `updateGit`),
  `editorBufferDidChange(paneId: String, tab: Int, text: String)`,
  `editorViewDidReport(paneId: String, tab: Int, cursor: EditorPosition, selection: EditorRange?, visibleRange: ClosedRange<Int>?, scrollTop: Double)`.
- Produces (pure, `EditorTabs`): `editorTabTitles(_ tabs: [EditorTab]) -> [String]`,
  `editorNextScratchNumber(_ tabs: [EditorTab]) -> Int`, `editorLanguage(forPath:) -> String`,
  `editorSavedTabs(_ s: EditorSnapshot) -> [EditorSavedTab]`, `editorCloseTarget(tabs: Int) -> EditorCloseTarget`
  (`.tab` / `.pane`), `editorTabAfterClosing(_ index: Int, count: Int) -> Int?`.
- Produces (layout): `Pane.editorTabs: [EditorSavedTab]?` (in `CodingKeys`),
  `LayoutStore.setEditorTabs(id: String, to: [EditorSavedTab])`, `LayoutStore.editorTabs(id:) -> [EditorSavedTab]?`.
- Produces (window): `WindowModel.editor(_ paneId: String) -> EditorSnapshot?`.

`EditorSavedTab` lives in `Layout/` (Pane uses it; `Layout/` must not use `Editor/`) — put it in
`Layout/Pane.swift` beside `Pane`, along with `EditorPosition` if the layering scanner reports
`Layout → Editor`; then `Editor/` uses `Layout/`, which it may. Run `LayeringTests` to confirm.

- [ ] **Step 1: Write the failing pure-rule tests** (`EditorTabsTests.swift`)

```swift
import Foundation
import Testing
@testable import WakilKit

private func fileTab(_ path: String, root: String = "/p/api") -> EditorTab {
    EditorTab.file(path: path, root: root, text: "", mtime: 1, language: editorLanguage(forPath: path))
}

@Test func titlesAreFileNames() {
    #expect(editorTabTitles([fileTab("/p/api/a.go"), fileTab("/p/api/b.go")]) == ["a.go", "b.go"])
}

@Test func titlesOfTwoSameNamedFilesNameTheirFolders() {
    let tabs = [fileTab("/p/api/src/config.go"), fileTab("/p/web/lib/config.go", root: "/p/web")]
    #expect(editorTabTitles(tabs) == ["src/config.go", "lib/config.go"])
}

@Test func scratchTitlesAreUntitledN() {
    #expect(editorTabTitles([EditorTab.scratch(number: 2, language: "plaintext")]) == ["Untitled-2"])
}

@Test func theNextScratchNumberIsOneAboveTheHighestOpen() {
    #expect(editorNextScratchNumber([]) == 1)
    #expect(editorNextScratchNumber([.scratch(number: 1, language: "sql"), .scratch(number: 3, language: "sql")]) == 4)
}

@Test func languageComesFromTheExtension() {
    #expect(editorLanguage(forPath: "/a/b.go") == "go")
    #expect(editorLanguage(forPath: "/a/b.tsx") == "typescript")
    #expect(editorLanguage(forPath: "/a/Dockerfile") == "dockerfile")
    #expect(editorLanguage(forPath: "/a/.env") == "ini")
    #expect(editorLanguage(forPath: "/a/b.unknown") == "plaintext")
}

@Test func commandWClosesATabWhileAnyIsOpenThenThePane() {
    #expect(editorCloseTarget(tabs: 2) == .tab)
    #expect(editorCloseTarget(tabs: 0) == .pane)
}

@Test func closingATabFocusesItsNeighbourNotTheFirst() {
    #expect(editorTabAfterClosing(2, count: 4) == 2)   // the tab that slid into its place
    #expect(editorTabAfterClosing(3, count: 4) == 2)   // the last tab: its left neighbour
    #expect(editorTabAfterClosing(0, count: 1) == nil)
}

@Test func savedTabsKeepFilesAndDropScratch() {
    var a = fileTab("/p/api/a.go"); a.cursor = EditorPosition(line: 40, column: 3); a.scrollTop = 120
    let s = EditorSnapshot(tabs: [a, .scratch(number: 1, language: "sql")], active: 0)
    #expect(editorSavedTabs(s) == [EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 40, column: 3), scrollTop: 120)])
}
```

Run: `cd app && ../scripts/swift-test.sh --filter EditorTabs`
Expected: FAIL — types not found.

- [ ] **Step 2: Write `EditorSnapshot.swift`** — the types in **Interfaces** with public memberwise
`init`s, plus two factories:

```swift
extension EditorTab {
    /// A file tab as just read: clean, in sync, cursor at 1:1.
    public static func file(path: String, root: String, text: String, mtime: Int64, language: String) -> EditorTab {
        EditorTab(subject: .file(path: path, root: root), text: text, savedText: text, language: language,
                  diskState: .inSync, mtime: mtime, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                  visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                  lastAgentEdit: nil)
    }

    /// An empty scratch tab.
    public static func scratch(number: Int, language: String) -> EditorTab {
        EditorTab(subject: .scratch(number: number), text: "", savedText: "", language: language,
                  diskState: .inSync, mtime: 0, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                  visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                  lastAgentEdit: nil)
    }

    public var path: String? { if case .file(let p, _) = subject { p } else { nil } }
    public var isScratch: Bool { if case .scratch = subject { true } else { false } }
}
```

- [ ] **Step 3: Write `EditorTabs.swift`**

```swift
import Foundation

/// What ⌘W closes in a focused editor pane: its active tab while any is open, else the pane.
public enum EditorCloseTarget: Sendable, Equatable { case tab, pane }

public func editorCloseTarget(tabs: Int) -> EditorCloseTarget { tabs > 0 ? .tab : .pane }

/// The tab focused after closing `index` of `count` (Rule 6: a neighbour, not the first).
public func editorTabAfterClosing(_ index: Int, count: Int) -> Int? {
    let remaining = count - 1
    guard remaining > 0 else { return nil }
    return min(index, remaining - 1)
}

/// Tab titles: the file name, or `parent/name` where two open files share a name; `Untitled-N`.
public func editorTabTitles(_ tabs: [EditorTab]) -> [String] {
    var counts: [String: Int] = [:]
    for tab in tabs { if let p = tab.path { counts[(p as NSString).lastPathComponent, default: 0] += 1 } }
    return tabs.map { tab in
        switch tab.subject {
        case .scratch(let n): return "Untitled-\(n)"
        case .file(let path, _):
            let name = (path as NSString).lastPathComponent
            guard counts[name, default: 0] > 1 else { return name }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return "\(parent)/\(name)"
        }
    }
}

public func editorNextScratchNumber(_ tabs: [EditorTab]) -> Int {
    var high = 0
    for tab in tabs { if case .scratch(let n) = tab.subject { high = max(high, n) } }
    return high + 1
}

/// Monaco's language id for a path, by extension or well-known name.
public func editorLanguage(forPath path: String) -> String {
    let name = (path as NSString).lastPathComponent.lowercased()
    switch name {
    case "dockerfile": return "dockerfile"
    case "makefile": return "plaintext"
    case ".env", ".env.local", ".env.example": return "ini"
    default: break
    }
    switch (name as NSString).pathExtension {
    case "go": return "go"
    case "swift": return "swift"
    case "php": return "php"
    case "ts", "tsx": return "typescript"
    case "js", "jsx", "mjs", "cjs": return "javascript"
    case "json": return "json"
    case "yml", "yaml": return "yaml"
    case "sql": return "sql"
    case "md": return "markdown"
    case "html", "vue": return "html"
    case "css": return "css"
    case "scss": return "scss"
    case "py": return "python"
    case "sh", "zsh", "bash": return "shell"
    case "xml": return "xml"
    case "ini", "toml", "env": return "ini"
    default: return "plaintext"
    }
}

/// The tabs a layout keeps: files only, with cursor and scroll. Scratch tabs and unsaved text
/// are never persisted (spec, Restore).
public func editorSavedTabs(_ s: EditorSnapshot) -> [EditorSavedTab] {
    s.tabs.compactMap { tab in
        tab.path.map { EditorSavedTab(path: $0, cursor: tab.cursor, scrollTop: tab.scrollTop) }
    }
}
```

Run: `cd app && ../scripts/swift-test.sh --filter EditorTabs`
Expected: PASS.

- [ ] **Step 4: Write the failing store and `read_pane` tests**

`EditorStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func editorStore() async -> (PaneStore, String) {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    return (PaneStore(kinds: PaneKinds.standard), pane)
}

@Test func typingMarksTheTabDirtyAndUndoingTheTypingCleansIt() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "abc", mtime: 1, language: "go")]; s.active = 0
    }
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "abcd")
    #expect(await store.editorSnapshot(paneId: pane).tabs[0].dirty)
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "abc")
    #expect(await !store.editorSnapshot(paneId: pane).tabs[0].dirty)
}

@Test func typingIntoATabThatNoLongerExistsIsDropped() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in s.tabs = []; s.active = nil }
    await store.editorBufferDidChange(paneId: pane, tab: 3, text: "x")
    #expect(await store.editorSnapshot(paneId: pane).tabs.isEmpty)
}

@Test func typingIntoAReadOnlyTabIsDropped() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        var t = EditorTab.file(path: "/p/l.txt", root: "/p", text: "", mtime: 1, language: "plaintext")
        t.readOnly = true
        s.tabs = [t]; s.active = 0
    }
    await store.editorBufferDidChange(paneId: pane, tab: 0, text: "x")
    #expect(await store.editorSnapshot(paneId: pane).tabs[0].text == "")
}

@Test func theViewsReportMovesCursorAndScrollWithoutDirtying() async {
    let (store, pane) = await editorStore()
    await store.updateEditor(paneId: pane, create: true) { s in
        s.tabs = [.file(path: "/p/a.go", root: "/p", text: "a\nb", mtime: 1, language: "go")]; s.active = 0
    }
    await store.editorViewDidReport(paneId: pane, tab: 0, cursor: EditorPosition(line: 2, column: 1),
                                    selection: nil, visibleRange: 1...2, scrollTop: 10)
    let t = await store.editorSnapshot(paneId: pane).tabs[0]
    #expect(t.cursor == EditorPosition(line: 2, column: 1))
    #expect(t.visibleRange == 1...2 && t.scrollTop == 10 && !t.dirty)
}
```

`EditorReadPaneTests.swift` (the golden `read_pane`, deferred by pane-kinds):

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func readPaneForAnEditorIsTheGoldenShape() async {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.updateEditor(paneId: pane, create: true) { s in
        var a = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "l1\nl2\nl3\nl4", mtime: 7, language: "go")
        a.text = "l1\nl2 edited\nl3\nl4"
        a.cursor = EditorPosition(line: 2, column: 4)
        a.selection = EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 3))
        a.visibleRange = 2...3
        s.tabs = [a, .scratch(number: 1, language: "sql")]
        s.active = 0
    }
    let read = await store.readPane(paneId: pane, kind: "editor")
    #expect(read == .object([
        "kind": .string("editor"),
        "failure": .null,
        "active": .number(0),
        "tabs": .array([
            .object(["path": .string("/p/api/a.go"), "scratch": .null, "root": .string("/p/api"),
                     "language": .string("go"), "dirty": .bool(true), "disk_state": .string("inSync"),
                     "notice": .null, "saving": .bool(false)]),
            .object(["path": .null, "scratch": .number(1), "root": .null,
                     "language": .string("sql"), "dirty": .bool(false), "disk_state": .string("inSync"),
                     "notice": .null, "saving": .bool(false)]),
        ]),
        "cursor": .object(["line": .number(2), "column": .number(4)]),
        "selection": .object(["start": .object(["line": .number(2), "column": .number(1)]),
                              "end": .object(["line": .number(2), "column": .number(3)])]),
        "visible_range": .object(["first": .number(2), "last": .number(3)]),
        "visible_text": .string("l2 edited\nl3"),
        "selected_text": .string("l2"),
    ]))
}

@Test func readPaneForANeverWrittenEditorHasEveryKeyEmpty() async {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let read = await PaneStore(kinds: PaneKinds.standard).readPane(paneId: pane, kind: "editor")
    guard case .object(let o) = read else { Issue.record("not an object"); return }
    for key in ["active", "tabs", "cursor", "selection", "visible_range", "visible_text", "selected_text"] {
        #expect(o[key] != nil, "missing \(key)")
    }
    #expect(o["tabs"] == .array([]) && o["active"] == .null)
}
```

Check how `readPane(paneId:kind:)` merges `kind`/`failure` (`Panes/PaneStore.swift`) and adjust the
golden's envelope keys to what it actually emits — the editor keys must not change.

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorStore|EditorReadPane'`
Expected: FAIL — `updateEditor` not found.

- [ ] **Step 5: Write `EditorPaneKind.swift`**

```swift
import Foundation

/// The editor pane (3b-i): tabs over the project's files and scratch buffers. Its contents are
/// its snapshot. The store owns every tab's text; Monaco mirrors it (`EditorRenderer`).
enum EditorPaneKind: PaneKind {
    static let names = ["editor"]
    static var emptyContents: EditorSnapshot { .empty }
    static var emptySnapshot: EditorSnapshot? { .empty }
    static func snapshot(of contents: EditorSnapshot, in store: isolated PaneStore) -> EditorSnapshot { contents }

    /// Every key always present. Whole-file text is left out — the agent reads files itself — so
    /// "this line" resolves against what is on screen (Invariant 3). No key may be `kind` or `failure`.
    static func readPane(_ s: EditorSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        func position(_ p: EditorPosition) -> JSONValue {
            .object(["line": .number(Double(p.line)), "column": .number(Double(p.column))])
        }
        var o: [String: JSONValue] = [:]
        o["tabs"] = .array(s.tabs.map { tab in
            var scratch: JSONValue = .null, path: JSONValue = .null, root: JSONValue = .null
            switch tab.subject {
            case .file(let p, let r): path = .string(p); root = .string(r)
            case .scratch(let n): scratch = .number(Double(n))
            }
            return .object([
                "path": path, "scratch": scratch, "root": root, "language": .string(tab.language),
                "dirty": .bool(tab.dirty), "disk_state": .string(tab.diskState.rawValue),
                "notice": tab.notice.map { .string($0) } ?? .null, "saving": .bool(tab.saving),
            ])
        })
        o["active"] = s.active.map { .number(Double($0)) } ?? .null
        let tab = s.active.flatMap { $0 < s.tabs.count ? s.tabs[$0] : nil }
        o["cursor"] = tab.map { position($0.cursor) } ?? .null
        o["selection"] = tab?.selection.map { .object(["start": position($0.start), "end": position($0.end)]) } ?? .null
        o["visible_range"] = tab?.visibleRange.map {
            .object(["first": .number(Double($0.lowerBound)), "last": .number(Double($0.upperBound))])
        } ?? .null
        o["visible_text"] = tab.flatMap { t in t.visibleRange.map { .string(editorLines(t.text, $0)) } } ?? .null
        o["selected_text"] = tab.flatMap { t in t.selection.map { .string(editorText(t.text, in: $0)) } } ?? .null
        return o
    }
}

extension PaneSnapshot {
    public var editor: EditorSnapshot? { contents as? EditorSnapshot }
}

extension EditorSnapshot: PaneKindSnapshot {}
```

Add to `EditorTabs.swift` the two text helpers (UTF-16 columns, as Monaco counts them):

```swift
/// Lines `range` (1-based, inclusive) of `text`, joined by "\n". Lines past the end are dropped.
public func editorLines(_ text: String, _ range: ClosedRange<Int>) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lo = max(range.lowerBound, 1) - 1, hi = min(range.upperBound, lines.count) - 1
    guard lo <= hi else { return "" }
    return lines[lo...hi].joined(separator: "\n")
}

/// The UTF-16 offset of a 1-based position, clamped to the text.
public func editorOffset(_ text: String, _ p: EditorPosition) -> Int {
    let u = Array(text.utf16)
    var line = 1, i = 0
    while line < p.line, i < u.count { if u[i] == 10 { line += 1 }; i += 1 }
    var col = 1
    while col < p.column, i < u.count, u[i] != 10 { i += 1; col += 1 }
    return i
}

/// The text inside `range`.
public func editorText(_ text: String, in range: EditorRange) -> String {
    let u = Array(text.utf16)
    let a = editorOffset(text, range.start), b = editorOffset(text, range.end)
    return String(decoding: u[min(a, b)..<max(a, b)], as: UTF16.self)
}

/// `text` with `range` replaced by `insert`.
public func editorReplacing(_ text: String, _ range: EditorRange, with insert: String) -> String {
    let u = Array(text.utf16)
    let a = editorOffset(text, range.start), b = editorOffset(text, range.end)
    return String(decoding: Array(u[..<min(a, b)]) + Array(insert.utf16) + Array(u[max(a, b)...]), as: UTF16.self)
}
```

Add to `EditorTabsTests.swift`:

```swift
@Test func replacingARangeUsesOneBasedUTF16Positions() {
    let r = EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 3))
    #expect(editorReplacing("ab\ncdé\n", r, with: "X") == "ab\nXé\n")
    #expect(editorText("ab\ncdé\n", in: r) == "cd")
}
```

- [ ] **Step 6: Write `PaneStore+Editor.swift`**

```swift
import Foundation

// The editor kind's store methods (3b-i).
extension PaneStore {
    public func editorSnapshot(paneId: String) -> EditorSnapshot { contents(EditorPaneKind.self, paneId) }

    /// Reads, changes and writes an editor pane's snapshot in one actor turn — the in-place update
    /// the pane-kinds work deferred to the editor. Same terms as `updateGit`: a pane this store holds
    /// nothing for gets an entry only when `create` says so.
    @discardableResult
    public func updateEditor<T: Sendable>(
        paneId: String, create: Bool = false, _ change: @Sendable (inout EditorSnapshot) -> T
    ) -> T {
        var s = editorSnapshot(paneId: paneId)
        let result = change(&s)
        if holdsContents(paneId: paneId) || create { setContents(EditorPaneKind.self, paneId, s) }
        return result
    }

    /// **The one non-action path** (design-language §11: the editor's text surface is the one
    /// partial exception to dual-drive). The operator's keystrokes land here, debounced by the view;
    /// nothing else may call it. A tab gone or read-only is left alone.
    public func editorBufferDidChange(paneId: String, tab: Int, text: String) {
        updateEditor(paneId: paneId) { s in
            guard tab < s.tabs.count, !s.tabs[tab].readOnly, s.tabs[tab].text != text else { return }
            s.tabs[tab].text = text
            s.tabs[tab].edits += 1
        }
    }

    /// Cursor, selection, visible lines and scroll as Monaco last reported them. Not a text change.
    public func editorViewDidReport(
        paneId: String, tab: Int, cursor: EditorPosition, selection: EditorRange?,
        visibleRange: ClosedRange<Int>?, scrollTop: Double
    ) {
        updateEditor(paneId: paneId) { s in
            guard tab < s.tabs.count else { return }
            s.tabs[tab].cursor = cursor
            s.tabs[tab].selection = selection
            s.tabs[tab].visibleRange = visibleRange
            s.tabs[tab].scrollTop = scrollTop
        }
    }
}
```

- [ ] **Step 7: Register the kind and persist saved tabs**

- `App/PaneKinds.swift`: add `EditorPaneKind.self` to `standard`.
- `Layout/Pane.swift`: `kinds` gains `"editor"`; `defaultTitle(kind:)` answers `"Editor"` for
  `"editor"` (as for `"git"`); add `EditorSavedTab` and `EditorPosition` here (moved out of
  `EditorSnapshot.swift`); add the property, after `terminalPath`:

```swift
    /// An **editor** pane's open files with cursor and scroll (3b-i) — `nil` for every other kind.
    /// **In `CodingKeys`**: which files were open is a setting, like `terminalPath`. Unsaved text and
    /// scratch tabs are never here (spec, Restore); `try?` for `fetch`'s reason.
    public var editorTabs: [EditorSavedTab]?
```

  Add `editorTabs` to `CodingKeys`, to `init(...)` (`editorTabs: [EditorSavedTab]? = nil`), and to
  `init(from:)`: `editorTabs = (try? container.decodeIfPresent([EditorSavedTab].self, forKey: .editorTabs)) ?? nil`.
- `Layout/LayoutStore.swift`, beside `setTerminalPath`:

```swift
    /// The editor pane `id`'s saved tabs (3b-i). A no-op when unchanged, so the window does not
    /// persist a layout for a cursor report that moved nothing.
    public func setEditorTabs(id: String, to tabs: [EditorSavedTab]) {
        guard var current = byScope[scope],
              let index = current.panes.firstIndex(where: { $0.id == id }),
              current.panes[index].editorTabs != tabs
        else { return }
        current.panes[index].editorTabs = tabs
        byScope[scope] = current
    }

    public func editorTabs(id: String) -> [EditorSavedTab]? {
        byScope[scope]?.panes.first(where: { $0.id == id })?.editorTabs
    }
```

- `App/WindowModel.swift`, beside `git(_:)`:
  `public func editor(_ paneId: String) -> EditorSnapshot? { paneCells[paneId]?.snapshot.editor }`.

Add a layout round-trip test to `EditorStoreTests.swift`:

```swift
@Test func savedTabsSurviveALayoutRoundTripAndAnOldLayoutDecodes() throws {
    let pane = Pane(id: "e", kind: "editor", title: "Editor", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1),
                    editorTabs: [EditorSavedTab(path: "/p/a.go", cursor: EditorPosition(line: 3, column: 2), scrollTop: 9)])
    let back = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
    #expect(back.editorTabs == pane.editorTabs)
    let old = #"{"id":"e","kind":"editor","title":"Editor","frame":{"x":0,"y":0,"width":1,"height":1}}"#
    #expect(try JSONDecoder().decode(Pane.self, from: Data(old.utf8)).editorTabs == nil)
}
```

- [ ] **Step 8: Docs heading** — `docs/architecture/wakilkit.md`, after `### Core/`:

```markdown
### Editor/ — the editor pane's logic

The `editor` kind (3b-i): `EditorSnapshot` (tabs: a file or a scratch buffer, its text and the text
last read or written, disk state, cursor and view), `EditorPaneKind` (`read_pane`: tabs, the active
tab's cursor, selection, visible lines and their text — never the whole file), `PaneStore+Editor`
(`updateEditor`; `editorBufferDidChange`, the one non-action path, for the operator's typing),
`EditorTabs` (titles, ⌘W's tab-then-pane rule, scratch numbers, language by extension, UTF-16 range
helpers), `EditorActions` and `EditorRenderer` (the seam Monaco sits behind). Uses `Panes/`, `Layout/`,
`Core/`, `Registry/`.
```

- [ ] **Step 9: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'Editor|PaneKinds|Layering|PaneKindClassification'`
Expected: PASS. `PaneKindsTests` passes with no change (registration, names in `Pane.kinds`, a
never-written pane answers). If `LayeringTests` reports a new link, fix the placement, don't extend the
allow-list.

- [ ] **Step 10: Commit**

```bash
git add app/Sources/WakilKit/Editor app/Sources/WakilKit/App/PaneKinds.swift app/Sources/WakilKit/Layout \
  app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/Editor*Tests.swift docs/architecture/wakilkit.md
git commit -m "Editor pane kind: tabs, store, read_pane, saved tabs in the layout (3b-i PR 3)"
```

---

### Task 4: The editor actions (PR 4)

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorActions.swift`, `app/Tests/WakilKitTests/EditorTestSupport.swift`, `app/Tests/WakilKitTests/EditorActionsTests.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (start `wakil-files`, register, `WakilWiring.filesClient`, `wakilOwnedClients`)

**Interfaces:**
- Consumes: Task 3's types and store; `ToolCaller`, `MCPClient.readReplyTimeout`, `mcpErrorText(from:)`,
  `optionalString`, `requireOpenPane`, `StandardActionError` (`missingParam`, `missingClient`).
- Produces: `public func registerEditorActions(into: ActionRegistry, panes: PaneStore, layout: LayoutStore?, files: (any ToolCaller)?, roots: @escaping @Sendable () async -> [String]) async`.
  Actions: `editor_open`, `editor_new_scratch`, `editor_focus_tab`, `editor_close`, `editor_goto`,
  `editor_select`, `editor_set_language`, `editor_replace_range`, `editor_save`, `editor_reload`,
  `editor_restore`.
  Every action takes an optional `pane`; with none it uses the focused editor pane, else the first
  editor pane, else opens one (`layout.open(kind: "editor", title: "Editor")`). Each returns the pane's
  `read_pane` plus `"pane": <id>`.
- Produces: `EditorActionError` (`notAFile`, `unsavedEdits(path:)`, `noScratchPath`, `noTab`).

Range params are `{start:{line,column}, end:{line,column}}`, 1-based.

- [ ] **Step 1: Write the fake and the fixture** (`EditorTestSupport.swift`)

```swift
import Foundation
import Testing
@testable import WakilKit

/// A wakil-files over an in-memory disk. Records calls; `slowWrite` parks `files_write` until
/// `releaseWrite()`, latched (FakeGit's lesson).
actor FakeFiles: ToolCaller {
    var disk: [String: (text: String, mtime: Int64)] = [:]
    var listing: [String: [String]] = [:]
    var calls: [String] = []
    var writeError: String?
    var slowWrite = false
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var clock: Int64 = 100

    func put(_ path: String, _ text: String) { clock += 1; disk[path] = (text, clock) }
    func remove(_ path: String) { disk[path] = nil }
    func setSlowWrite(_ on: Bool) { slowWrite = on }
    func setWriteError(_ e: String?) { writeError = e }
    func releaseWrite() { released = true; parked.forEach { $0.resume() }; parked = [] }
    private func park(_ c: CheckedContinuation<Void, Never>) { if released { c.resume() } else { parked.append(c) } }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let path = optionalString(arguments, "path") ?? optionalString(arguments, "root") ?? ""
        calls.append("\(name) \(path)")
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        switch name {
        case "files_read":
            guard let f = disk[path] else { return ok(["path": .string(path), "exists": .bool(false), "text": .string(""),
                                                      "utf8": .bool(true), "binary": .bool(false), "over_cap": .bool(false),
                                                      "size": .integer(0), "mtime": .integer(0)]) }
            return ok(["path": .string(path), "exists": .bool(true), "text": .string(f.text), "utf8": .bool(true),
                       "binary": .bool(false), "over_cap": .bool(false), "size": .integer(Int64(f.text.utf8.count)),
                       "mtime": .integer(f.mtime)])
        case "files_write":
            if slowWrite { await withCheckedContinuation { c in Task { self.park(c) } } }
            try Task.checkCancellation()
            if let writeError {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(writeError)])])])
            }
            if case .bool(false)? = arguments.objectValue?["create"], disk[path] == nil {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("\(path) does not exist")])])])
            }
            put(path, optionalString(arguments, "text") ?? "")
            return ok(["path": .string(path), "size": .integer(Int64(disk[path]!.text.utf8.count)), "mtime": .integer(disk[path]!.mtime)])
        case "files_list":
            return ok(["root": .string(path), "files": .array((listing[path] ?? []).map { .string($0) }), "truncated": .bool(false)])
        default:
            throw StandardActionError.missingClient(action: name, role: "files")
        }
    }
}

struct EditorFixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let layout: LayoutStore
    let files: FakeFiles
    var pane: String

    @discardableResult
    func dispatch(_ name: String, _ params: [String: JSONValue] = [:], origin: ActionOrigin = .agent,
                  environment: String = "staging") async throws -> JSONValue {
        var p = params
        if p["pane"] == nil { p["pane"] = .string(pane) }
        return try await registry.dispatch(name: name, params: .object(p), origin: origin,
                                           environment: environment, confirmation: nil)
    }
    func snapshot() async -> EditorSnapshot { await panes.editorSnapshot(paneId: pane) }
}

func editorFixture(roots: [String] = ["/p/api", "/p/web"]) async throws -> EditorFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let panes = PaneStore(kinds: PaneKinds.standard)
    let files = FakeFiles()
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: files, roots: { roots })
    return EditorFixture(registry: registry, panes: panes, layout: layout, files: files, pane: pane)
}

func range(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int) -> JSONValue {
    .object(["start": .object(["line": .integer(Int64(l1)), "column": .integer(Int64(c1))]),
             "end": .object(["line": .integer(Int64(l2)), "column": .integer(Int64(c2))])])
}
```

Check `JSONValue` for `.integer`'s payload type and an `objectValue` accessor; use what exists
(`GitTestSupport.swift` uses `.integer(0)`). Check `ActionOrigin`'s cases (`.agent`, `.ui`, `.voice`).

- [ ] **Step 2: Write the failing action tests** (`EditorActionsTests.swift`)

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func openReadsTheFileIntoANewActiveTabAtTheLine() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "l1\nl2\nl3")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "line": .integer(2)])
    let s = await f.snapshot()
    #expect(s.tabs.count == 1 && s.active == 0)
    #expect(s.tabs[0].subject == .file(path: "/p/api/a.go", root: "/p/api"))
    #expect(s.tabs[0].text == "l1\nl2\nl3" && !s.tabs[0].dirty && s.tabs[0].language == "go")
    #expect(s.tabs[0].cursor == EditorPosition(line: 2, column: 1))
    #expect(await f.layout.editorTabs(id: f.pane)?.map(\.path) == ["/p/api/a.go"])
}

@Test func openingAnOpenFileFocusesItsTabAndDoesNotReread() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a"); await f.files.put("/p/api/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    #expect(await f.snapshot().active == 0)
    #expect(await f.files.calls.filter { $0 == "files_read /p/api/a.go" }.count == 1)
}

@Test func openingASameNamedFileInAnotherRootOpensANewTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/config.go", "a"); await f.files.put("/p/web/config.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/config.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/web/config.go")])
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 1 && s.tabs[1].text == "b")
}

@Test func openWithNoPaneOpensAnEditorPane() async throws {
    let f = try await editorFixture()
    await f.layout.close(id: f.pane)
    await f.files.put("/p/api/a.go", "a")
    let reply = try await f.registry.dispatch(name: "editor_open", params: .object(["path": .string("/p/api/a.go")]),
                                              origin: .agent, environment: "staging", confirmation: nil)
    let opened = await f.layout.snapshot().panes.filter { $0.kind == "editor" }
    #expect(opened.count == 1)
    #expect(optionalString(reply, "pane") == opened[0].id)
}

@Test func openOfAPathOutsideTheRootsIsRefusedNamingTheDecision() async throws {
    let f = try await editorFixture()
    await #expect(throws: (any Error).self) { try await f.dispatch("editor_open", ["path": .string("/etc/hosts")]) }
    #expect(await f.snapshot().tabs.isEmpty)
}

@Test func anOverCapFileOpensReadOnlyWithItsNoticeWhole() async throws {
    let f = try await editorFixture()
    // FakeFiles has no over-cap mode: give it one for this test by writing the reply shape directly.
    // (Add `func putOverCap(_ path: String, size: Int)` to FakeFiles answering over_cap true.)
    await f.files.putOverCap("/p/api/dump.sql", size: 48_000_000)
    try await f.dispatch("editor_open", ["path": .string("/p/api/dump.sql")])
    let t = await f.snapshot().tabs[0]
    #expect(t.readOnly && t.text.isEmpty)
    #expect(t.notice == "dump.sql is 48 MB; files over 2 MB open in 3b-v")
}

@Test func newScratchOpensAnEmptyFocusedUntitledTab() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_new_scratch", ["language": .string("sql")], origin: .ui)
    let s = await f.snapshot()
    #expect(s.tabs.map(\.subject) == [.scratch(number: 1), .scratch(number: 2)])
    #expect(s.active == 1 && s.tabs[1].language == "sql")
    #expect(await f.layout.editorTabs(id: f.pane) == [], "scratch tabs are never persisted")
}

@Test func replaceRangeEditsTheBufferAndLeavesItUnsaved() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "if x == nil {\n}")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_replace_range", ["range": range(1, 4, 1, 5), "text": .string("y")])
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "if y == nil {\n}" && t.dirty)
    #expect(t.lastAgentEdit?.text == "y" && t.lastAgentEdit?.serial == 1)
    #expect(await f.files.disk["/p/api/a.go"]?.text == "if x == nil {\n}", "the disk changes only on save")
}

@Test func replaceRangeAppliesToTheTextAsTypedSoFar() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "abc")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "abcdef")
    try await f.dispatch("editor_replace_range", ["range": range(1, 1, 1, 2), "text": .string("X")])
    #expect(await f.snapshot().tabs[0].text == "Xbcdef")
}

@Test func saveWritesTheBufferWithoutAPromptEvenInProduction() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "old")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "new")
    try await f.dispatch("editor_save", origin: .voice, environment: "production")
    #expect(await f.files.disk["/p/api/a.go"]?.text == "new")
    let t = await f.snapshot().tabs[0]
    #expect(!t.dirty && !t.saving && t.mtime == (await f.files.disk["/p/api/a.go"]!.mtime))
}

@Test func aSaveThatLandsAfterMoreTypingLeavesTheTabDirty() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1")
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[0].saving { await Task.yield() }
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v2")
    await f.files.releaseWrite()
    _ = try await save.value
    let t = await f.snapshot().tabs[0]
    #expect(t.savedText == "v1" && t.text == "v2" && t.dirty)
}

@Test func aSecondSaveWhileOneIsInFlightDoesNothing() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1")
    await f.files.setSlowWrite(true)
    let first = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[0].saving { await Task.yield() }
    try await f.dispatch("editor_save", origin: .ui)
    await f.files.releaseWrite()
    _ = try await first.value
    #expect(await f.files.calls.filter { $0.hasPrefix("files_write") }.count == 1)
}

@Test func aCancelledSaveLeavesTheBufferDirtyAndNotSaving() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1")
    await f.files.setSlowWrite(true)
    let save = Task { try await f.dispatch("editor_save", origin: .ui) }
    while await !f.snapshot().tabs[0].saving { await Task.yield() }
    save.cancel()
    await f.files.releaseWrite()
    _ = try? await save.value
    let t = await f.snapshot().tabs[0]
    #expect(t.dirty && !t.saving)
}

@Test func aFailedWriteShowsTheErrorWholeAndKeepsTheBufferDirty() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1")
    let long = "open /p/api/a.go: permission denied " + String(repeating: "x", count: 400)
    await f.files.setWriteError(long)
    try? await f.dispatch("editor_save", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.notice == long && t.dirty && !t.saving)
}

@Test func savingAScratchTabAsAPathMakesItThatFile() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", ["language": .string("sql")], origin: .ui)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "select 1")
    try await f.dispatch("editor_save", ["as": .string("/p/api/q/one.sql")], origin: .ui)
    #expect(await f.files.disk["/p/api/q/one.sql"]?.text == "select 1")
    let t = await f.snapshot().tabs[0]
    #expect(t.subject == .file(path: "/p/api/q/one.sql", root: "/p/api") && !t.dirty)
    #expect(await f.layout.editorTabs(id: f.pane)?.map(\.path) == ["/p/api/q/one.sql"])
}

@Test func savingAScratchTabWithNoPathSaysSo() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    await #expect(throws: EditorActionError.noScratchPath) { try await f.dispatch("editor_save", origin: .ui) }
}

@Test func closingADirtyTabWithoutDiscardIsRefusedAndKeepsIt() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "b")
    await #expect(throws: EditorActionError.unsavedEdits(path: "/p/api/a.go")) { try await f.dispatch("editor_close") }
    #expect(await f.snapshot().tabs.count == 1)
    try await f.dispatch("editor_close", ["discard": .bool(true)])
    #expect(await f.snapshot().tabs.isEmpty)
}

@Test func closingATabFocusesItsNeighbour() async throws {
    let f = try await editorFixture()
    for n in ["a", "b", "c"] { await f.files.put("/p/api/\(n).go", n); try await f.dispatch("editor_open", ["path": .string("/p/api/\(n).go")]) }
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    try await f.dispatch("editor_close")
    let s = await f.snapshot()
    #expect(s.tabs.compactMap(\.path) == ["/p/api/a.go", "/p/api/c.go"] && s.active == 1)
}

@Test func closingAnEmptyScratchTabNeedsNoDiscard() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_close")
    #expect(await f.snapshot().tabs.isEmpty)
}

@Test func gotoAndSelectMoveTheActiveTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "l1\nl2\nl3")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_goto", ["line": .integer(3), "column": .integer(2)])
    #expect(await f.snapshot().tabs[0].cursor == EditorPosition(line: 3, column: 2))
    try await f.dispatch("editor_select", ["range": range(2, 1, 2, 3)])
    #expect(await f.snapshot().tabs[0].selection == EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 3)))
}

@Test func setLanguageChangesTheActiveTabsLanguage() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_set_language", ["language": .string("json")], origin: .ui)
    #expect(await f.snapshot().tabs[0].language == "json")
}

@Test func reloadReplacesTheBufferWithTheDisk() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine")
    await f.files.put("/p/api/a.go", "theirs")
    try await f.dispatch("editor_reload", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "theirs" && !t.dirty && t.diskState == .inSync)
}

@Test func restoreReopensSavedTabsAndMarksAMissingOneDeleted() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    await f.layout.setEditorTabs(id: f.pane, to: [
        EditorSavedTab(path: "/p/api/a.go", cursor: EditorPosition(line: 1, column: 1), scrollTop: 30),
        EditorSavedTab(path: "/p/api/gone.go", cursor: EditorPosition(line: 4, column: 1), scrollTop: 0),
    ])
    try await f.dispatch("editor_restore", origin: .ui)
    let s = await f.snapshot()
    #expect(s.tabs.count == 2 && s.active == 0)
    #expect(s.tabs[0].text == "a" && s.tabs[0].scrollTop == 30)
    #expect(s.tabs[1].diskState == .deleted && s.tabs[1].cursor == EditorPosition(line: 4, column: 1))
}

@Test func focusTabSetsTheActiveTab() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_new_scratch", origin: .ui)
    try await f.dispatch("editor_focus_tab", ["index": .integer(0)], origin: .ui)
    #expect(await f.snapshot().active == 0)
    await #expect(throws: EditorActionError.noTab(action: "editor_focus_tab")) {
        try await f.dispatch("editor_focus_tab", ["index": .integer(5)], origin: .ui)
    }
}

@Test func saveDeclaresAllowEverywhere() async throws {
    let f = try await editorFixture()
    let save = try #require(await f.registry.all().first { $0.name == "editor_save" })
    #expect(save.price.production == .allow && save.price.otherwise == .allow)
    #expect(save.kind == .mutate && save.audience == .agentReachable)
}
```

Add `putOverCap` to `FakeFiles` (answers `exists: true, over_cap: true, text: "", size: <size>`).
Check `ActionRegistry.all()`'s descriptor fields for `price`/`kind`/`audience` and adjust the last test.

Run: `cd app && ../scripts/swift-test.sh --filter EditorActions`
Expected: FAIL — `registerEditorActions` not found.

- [ ] **Step 3: Implement `EditorActions.swift`**

```swift
import Foundation

/// Errors the editor actions raise for reasons of their own. Each reads whole (Rule 8).
public enum EditorActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsavedEdits(path: String)
    case noScratchPath
    case noTab(action: String)
    case notAFile(action: String)

    public var description: String {
        switch self {
        case .unsavedEdits(let path):
            "editor_close: \(path) has unsaved edits; save it, or close with discard true to drop them"
        case .noScratchPath:
            "editor_save: a scratch tab needs a path to save as (as, an absolute path inside a root)"
        case .noTab(let action): "\(action): the editor pane has no open tab"
        case .notAFile(let action): "\(action): the tab is a scratch buffer, not a file"
        }
    }
}

private enum FilesOutcome: Sendable { case ok([String: JSONValue]); case failed(String) }

private func filesTool(_ files: any ToolCaller, _ name: String, _ args: [String: JSONValue]) async throws -> FilesOutcome {
    let result: JSONValue
    do {
        result = try await files.callTool(name: name, arguments: .object(args), timeout: MCPClient.readReplyTimeout)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if Task.isCancelled { throw CancellationError() }
        return .failed(String(describing: error))
    }
    guard case .object(let obj) = result else { return .failed("\(name) answered with no object") }
    if case .bool(true)? = obj["isError"] { return .failed(mcpErrorText(from: obj) ?? "\(name) failed with no message") }
    guard case .object(let content)? = obj["structuredContent"] else { return .failed("\(name) answered with no structuredContent") }
    return .ok(content)
}

/// Thrown when wakil-files refused or failed: its text, whole.
struct EditorFilesError: Error, CustomStringConvertible { let description: String }

private func position(_ v: JSONValue?) -> EditorPosition? {
    guard case .object(let o)? = v, let line = o["line"]?.intValue else { return nil }
    return EditorPosition(line: line, column: o["column"]?.intValue ?? 1)
}

private func editorRange(_ v: JSONValue?) -> EditorRange? {
    guard case .object(let o)? = v, let s = position(o["start"]), let e = position(o["end"]) else { return nil }
    return EditorRange(start: s, end: e)
}

private func megabytes(_ bytes: Int) -> String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }

/// A tab from a `files_read` reply. Over the cap, binary or not UTF-8 opens read-only with a notice.
func editorTab(fromRead o: [String: JSONValue], path: String, root: String) -> EditorTab {
    let name = (path as NSString).lastPathComponent
    let text: String = { if case .string(let s)? = o["text"] { s } else { "" } }()
    var tab = EditorTab.file(path: path, root: root, text: text, mtime: Int64(o["mtime"]?.intValue ?? 0),
                             language: editorLanguage(forPath: path))
    if o["exists"] == .bool(false) { tab.diskState = .deleted }
    if o["over_cap"] == .bool(true) {
        tab.readOnly = true
        tab.notice = "\(name) is \(megabytes(o["size"]?.intValue ?? 0)); files over 2 MB open in 3b-v"
    } else if o["binary"] == .bool(true) {
        tab.readOnly = true
        tab.notice = "\(name) is a binary file"
    } else if o["utf8"] == .bool(false) {
        tab.readOnly = true
        tab.notice = "\(name) is not UTF-8; it opens read-only"
    }
    return tab
}

/// Registers the editor pane's actions (3b-i).
///
/// **One path for the operator and the agent** (Invariant 2): ⌘P, ⌘T, ⌘S, ⌘W and the pane's buttons
/// dispatch these. The operator's typing is the one exception (`PaneStore.editorBufferDidChange`).
/// Each answers the pane's `read_pane` plus its `pane` id.
public func registerEditorActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore?,
    files: (any ToolCaller)?,
    roots: @escaping @Sendable () async -> [String]
) async {
    @Sendable func requireFiles(_ action: String) throws -> any ToolCaller {
        guard let files else { throw StandardActionError.missingClient(action: action, role: "files") }
        return files
    }

    /// The named pane, else the focused editor pane, else the first, else a new one.
    @Sendable func editorPane(_ params: JSONValue, action: String) async throws -> String {
        if let pane = optionalString(params, "pane"), !pane.isEmpty {
            try await requireOpenPane(pane, action: action, layout: layout)
            return pane
        }
        guard let layout else { throw StandardActionError.missingParam(action: action, param: "pane") }
        let snap = await layout.snapshot()
        let editors = snap.panes.filter { $0.kind == "editor" }
        if let focused = snap.focusedId, editors.contains(where: { $0.id == focused }) { return focused }
        if let first = editors.first { return first.id }
        return await layout.open(kind: "editor", title: Pane.defaultTitle(kind: "editor")).id
    }

    @Sendable func reply(_ pane: String) async -> JSONValue {
        guard case .object(var o) = await panes.readPane(paneId: pane, kind: "editor") else { return .null }
        o["pane"] = .string(pane)
        return .object(o)
    }

    @Sendable func persist(_ pane: String) async {
        await layout?.setEditorTabs(id: pane, to: editorSavedTabs(panes.editorSnapshot(paneId: pane)))
    }

    /// The root holding `path`, or the refusal Rule 7 allows (an invariant forbids it).
    @Sendable func root(of path: String, action: String) async throws -> String {
        for r in await roots() where path == r || path.hasPrefix(r + "/") { return r }
        throw EditorFilesError(description: "\(action): \(path) is outside the active project's roots; "
            + "editor reads and writes are confined to them (Invariant 6, Decision 36)")
    }

    @Sendable func read(_ path: String, action: String) async throws -> EditorTab {
        let r = try await root(of: path, action: action)
        switch try await filesTool(try requireFiles(action), "files_read", ["path": .string(path)]) {
        case .failed(let text): throw EditorFilesError(description: text)
        case .ok(let o): return editorTab(fromRead: o, path: path, root: r)
        }
    }

    /// The tab index `params`' optional `path` names in `pane`, else the active tab.
    @Sendable func tabIndex(_ pane: String, _ params: JSONValue, action: String) async throws -> Int {
        let s = await panes.editorSnapshot(paneId: pane)
        if let path = optionalString(params, "path") {
            guard let i = s.tabs.firstIndex(where: { $0.path == path }) else { throw EditorActionError.noTab(action: action) }
            return i
        }
        guard let i = s.active, i < s.tabs.count else { throw EditorActionError.noTab(action: action) }
        return i
    }

    func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var props = properties
        props["pane"] = .object(["type": .string("string")])
        return .object(["type": .string("object"), "properties": .object(props),
                        "required": .array(required.map { .string($0) })])
    }
    let positionSchema: JSONValue = .object(["type": .string("object"), "properties": .object([
        "line": .object(["type": .string("integer")]), "column": .object(["type": .string("integer")])])])
    let rangeSchema: JSONValue = .object(["type": .string("object"), "properties": .object([
        "start": positionSchema, "end": positionSchema])])

    await registry.register(Action(
        name: "editor_open",
        description: "Open a file (path, absolute, inside one of the active project's roots) in an editor "
            + "pane — a new tab, or its tab if already open — and reveal line (1-based) and column. With no "
            + "pane, the focused or first editor pane, or a new one. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "line": .object(["type": .string("integer")]),
                        "column": .object(["type": .string("integer")])], required: ["path"]),
        handler: { params in
            guard let path = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_open", param: "path")
            }
            _ = try await root(of: path, action: "editor_open")
            let pane = try await editorPane(params, action: "editor_open")
            let line = (params.objectValue?["line"]?.intValue).map { EditorPosition(line: $0, column: params.objectValue?["column"]?.intValue ?? 1) }
            let open = await panes.editorSnapshot(paneId: pane).tabs.firstIndex { $0.path == path }
            if let open {
                await panes.updateEditor(paneId: pane, create: true) { s in
                    s.active = open
                    if let line { s.tabs[open].cursor = line }
                }
            } else {
                var tab = try await read(path, action: "editor_open")
                if let line { tab.cursor = line }
                await panes.updateEditor(paneId: pane, create: true) { s in
                    s.tabs.append(tab)
                    s.active = s.tabs.count - 1
                }
            }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_new_scratch",
        description: "Open an empty scratch tab (Untitled-N) in an editor pane, in language (a Monaco "
            + "language id; plaintext by default). Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["language": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_new_scratch")
            let language = optionalString(params, "language") ?? "plaintext"
            await panes.updateEditor(paneId: pane, create: true) { s in
                s.tabs.append(.scratch(number: editorNextScratchNumber(s.tabs), language: language))
                s.active = s.tabs.count - 1
            }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_focus_tab",
        description: "Make tab index (0-based, in tab-strip order) the editor pane's active tab.",
        kind: .control, audience: .agentReachable,
        schema: schema(["index": .object(["type": .string("integer")])], required: ["index"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_focus_tab")
            guard let index = params.objectValue?["index"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_focus_tab", param: "index")
            }
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                guard index >= 0, index < s.tabs.count else { return false }
                s.active = index
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_focus_tab") }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_close",
        description: "Close a tab (path, or the active tab). A tab with unsaved edits closes only with "
            + "discard true; otherwise this answers that it has unsaved edits. Focus moves to a neighbour.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "discard": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_close")
            let index = try await tabIndex(pane, params, action: "editor_close")
            let discard = params.objectValue?["discard"] == .bool(true)
            let tab = await panes.editorSnapshot(paneId: pane).tabs[index]
            if tab.dirty, !discard {
                throw EditorActionError.unsavedEdits(path: tab.path ?? editorTabTitles([tab])[0])
            }
            await panes.updateEditor(paneId: pane) { s in
                guard index < s.tabs.count else { return }
                let count = s.tabs.count
                s.tabs.remove(at: index)
                s.active = editorTabAfterClosing(index, count: count)
            }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_goto",
        description: "Move the active tab's cursor to line (1-based) and column, revealing it.",
        kind: .control, audience: .agentReachable,
        schema: schema(["line": .object(["type": .string("integer")]), "column": .object(["type": .string("integer")])], required: ["line"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_goto")
            guard let line = params.objectValue?["line"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_goto", param: "line")
            }
            let index = try await tabIndex(pane, .object([:]), action: "editor_goto")
            let column = params.objectValue?["column"]?.intValue ?? 1
            await panes.updateEditor(paneId: pane) { s in s.tabs[index].cursor = EditorPosition(line: line, column: column) }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_select",
        description: "Select range ({start:{line,column}, end:{line,column}}, 1-based) in the active tab.",
        kind: .control, audience: .agentReachable,
        schema: schema(["range": rangeSchema], required: ["range"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_select")
            guard let r = editorRange(params.objectValue?["range"]) else {
                throw StandardActionError.missingParam(action: "editor_select", param: "range")
            }
            let index = try await tabIndex(pane, .object([:]), action: "editor_select")
            await panes.updateEditor(paneId: pane) { s in s.tabs[index].selection = r; s.tabs[index].cursor = r.end }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_set_language",
        description: "Set the active tab's language (a Monaco language id: sql, json, go, …).",
        kind: .control, audience: .agentReachable,
        schema: schema(["language": .object(["type": .string("string")])], required: ["language"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_set_language")
            guard let language = optionalString(params, "language") else {
                throw StandardActionError.missingParam(action: "editor_set_language", param: "language")
            }
            let index = try await tabIndex(pane, .object([:]), action: "editor_set_language")
            await panes.updateEditor(paneId: pane) { s in s.tabs[index].language = language }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_replace_range",
        description: "Replace range ({start,end}, 1-based) of a tab's buffer (path, or the active tab) with "
            + "text. The change is unsaved; editor_save writes it. Undoable with ⌘Z in the pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "range": rangeSchema,
                        "text": .object(["type": .string("string")])], required: ["range", "text"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_replace_range")
            guard let r = editorRange(params.objectValue?["range"]) else {
                throw StandardActionError.missingParam(action: "editor_replace_range", param: "range")
            }
            guard let text = optionalString(params, "text") else {
                throw StandardActionError.missingParam(action: "editor_replace_range", param: "text")
            }
            let index = try await tabIndex(pane, params, action: "editor_replace_range")
            await panes.updateEditor(paneId: pane) { s in
                guard index < s.tabs.count, !s.tabs[index].readOnly else { return }
                s.tabs[index].text = editorReplacing(s.tabs[index].text, r, with: text)
                s.tabs[index].edits += 1
                let serial = (s.tabs[index].lastAgentEdit?.serial ?? 0) + 1
                s.tabs[index].lastAgentEdit = EditorAgentEdit(serial: serial, range: r, text: text)
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_save",
        description: "Write a tab's buffer to disk (path, or the active tab). A scratch tab needs as (an "
            + "absolute path inside a root) and becomes that file. Writes over a file changed on disk. "
            + "Confined to the active project's roots (Invariant 6, Decision 36). Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "as": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_save")
            let index = try await tabIndex(pane, params, action: "editor_save")
            let files = try requireFiles("editor_save")
            let tab = await panes.editorSnapshot(paneId: pane).tabs[index]
            guard !tab.saving else { return await reply(pane) }   // Rule 5
            let target: String
            switch tab.subject {
            case .file(let path, _): target = path
            case .scratch:
                guard let saveAs = optionalString(params, "as"), !saveAs.isEmpty else { throw EditorActionError.noScratchPath }
                target = saveAs
            }
            let targetRoot = try await root(of: target, action: "editor_save")
            let text = tab.text
            let subject = tab.subject
            await panes.updateEditor(paneId: pane) { s in if index < s.tabs.count { s.tabs[index].saving = true } }
            let outcome: FilesOutcome
            do {
                outcome = try await filesTool(files, "files_write", [
                    "path": .string(target), "text": .string(text), "create": .bool(tab.isScratch || tab.diskState == .deleted),
                ])
            } catch {
                await panes.updateEditor(paneId: pane) { s in
                    if let i = s.tabs.firstIndex(where: { $0.subject == subject }) { s.tabs[i].saving = false }
                }
                throw error
            }
            await panes.updateEditor(paneId: pane) { s in
                guard let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
                s.tabs[i].saving = false
                switch outcome {
                case .failed(let message):
                    s.tabs[i].notice = message
                case .ok(let o):
                    s.tabs[i].savedText = text
                    s.tabs[i].mtime = Int64(o["mtime"]?.intValue ?? 0)
                    s.tabs[i].diskState = .inSync
                    s.tabs[i].notice = nil
                    if case .scratch = subject {
                        s.tabs[i].subject = .file(path: target, root: targetRoot)
                    }
                }
            }
            if case .failed(let message) = outcome { throw EditorFilesError(description: message) }
            await persist(pane)
            return await reply(pane)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_reload",
        description: "Replace a tab's buffer (path, or the active tab) with the file on disk, dropping "
            + "unsaved edits. Keeps cursor and scroll.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_reload")
            let index = try await tabIndex(pane, params, action: "editor_reload")
            let old = await panes.editorSnapshot(paneId: pane).tabs[index]
            guard let path = old.path else { throw EditorActionError.notAFile(action: "editor_reload") }
            var fresh = try await read(path, action: "editor_reload")
            fresh.cursor = old.cursor
            fresh.scrollTop = old.scrollTop
            fresh.language = old.language
            fresh.edits = old.edits + 1
            await panes.updateEditor(paneId: pane) { s in
                if let i = s.tabs.firstIndex(where: { $0.path == path }) { s.tabs[i] = fresh }
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_restore",
        description: "Reopen an editor pane's saved tabs (its files, cursors and scroll) after a relaunch. "
            + "A file that no longer exists comes back marked deleted.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_restore")
            let saved = await layout?.editorTabs(id: pane) ?? []
            var tabs: [EditorTab] = []
            for s in saved {
                guard var tab = try? await read(s.path, action: "editor_restore") else { continue }
                tab.cursor = s.cursor
                tab.scrollTop = s.scrollTop
                tabs.append(tab)
            }
            await panes.updateEditor(paneId: pane, create: true) { s in
                s.tabs = tabs
                s.active = tabs.isEmpty ? nil : 0
            }
            return await reply(pane)
        }))
}
```

Then `EditorPaneKind` gains the restore step (Task 2's hook):

```swift
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        guard let tabs = pane.editorTabs, !tabs.isEmpty else { return nil }
        return PaneRestoreStep(action: "editor_restore", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
```

Check `JSONValue` for `objectValue` and `intValue`; if `objectValue` is missing, add a small private
helper in this file (`guard case .object(let o) = params`). If `requireOpenPane` takes the pane as
its first unlabeled argument (it does), keep the call as written.

- [ ] **Step 4: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorActions|EditorStore|EditorReadPane|ActionClassification'`
Expected: PASS. `ActionClassificationTests` may pin the full registry list; add the ten editor actions
to its pinned list, all `.agentReachable`.

- [ ] **Step 5: Wire it** (`App/AppWiring.swift`)

After `let gitClient = await startClient("wakil-git")`:

```swift
        // 3b-i, eager for the git client's reason: an editor's first open must find it up.
        let filesClient = await startClient("wakil-files")
```

After `registerGitActions(…)`:

```swift
        await registerEditorActions(
            into: registry, panes: panes, layout: layout, files: filesClient,
            roots: { await gitRoots.current() })
```

Add `filesClient: MCPClient?` to `WakilWiring` (property and init, beside `gitClient`) and to
`wakilOwnedClients` (`everyWakilOwnedClientJoinsTheOrgSwitch` fails otherwise). Pass `filesClient`
where `gitClient` is passed in the `WakilWiring(...)` call.

Run: `cd app && ../scripts/swift-test.sh --filter 'Wiring|OrgSwitch|WakilOwned'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorActions.swift app/Sources/WakilKit/Editor/EditorPaneKind.swift \
  app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/EditorTestSupport.swift \
  app/Tests/WakilKitTests/EditorActionsTests.swift app/Tests/WakilKitTests/ActionClassificationTests.swift
git commit -m "Editor actions: open, scratch, close, goto, select, language, replace, save, reload, restore (3b-i PR 4)"
```

---

### Task 5: Disk changes — `editor_refresh` and the watcher (PR 5)

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift` (add `editor_refresh`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (an editor watcher beside `gitWatcher`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (`WakilWiring.editorRootWatcher: FSEventsRootWatcher()`)
- Test: `app/Tests/WakilKitTests/EditorRefreshTests.swift`, `app/Tests/WakilKitTests/WindowModelEditorTests.swift`

**Interfaces:**
- Produces: action `editor_refresh {pane?, root?}` — re-reads every open file tab (under `root` if
  given) and applies the disk rules. Pure: `editorAfterDiskRead(_ tab: EditorTab, read: EditorTab) -> EditorTab`.
- Produces: `WindowModel` init param `editorRootWatcher: (any RootWatcher)? = nil`; a private
  `syncEditorWatcher()` called wherever `syncGitWatcher()` is.

- [ ] **Step 1: Write the failing tests** (`EditorRefreshTests.swift`)

```swift
import Foundation
import Testing
@testable import WakilKit

private func openA(_ f: EditorFixture, _ text: String = "a") async throws {
    await f.files.put("/p/api/a.go", text)
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
}

@Test func aCleanTabReloadsInPlaceKeepingCursorAndScroll() async throws {
    let f = try await editorFixture()
    try await openA(f, "one\ntwo")
    await f.panes.editorViewDidReport(paneId: f.pane, tab: 0, cursor: EditorPosition(line: 2, column: 2),
                                      selection: nil, visibleRange: 1...2, scrollTop: 40)
    await f.files.put("/p/api/a.go", "one\ntwo\nthree")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "one\ntwo\nthree" && !t.dirty && t.diskState == .inSync)
    #expect(t.cursor == EditorPosition(line: 2, column: 2) && t.scrollTop == 40)
}

@Test func aDirtyTabKeepsTheOperatorsTextAndIsMarkedChangedOnDisk() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine")
    await f.files.put("/p/api/a.go", "theirs")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "mine" && t.diskState == .changedOnDisk)
}

@Test func aDiskChangeMatchingTheBufferMarksTheTabClean() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "same")
    await f.files.put("/p/api/a.go", "same")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(!t.dirty && t.diskState == .inSync && t.savedText == "same")
}

@Test func aDeletedFileKeepsItsTabAndTextMarkedDeletedAndSaveRecreatesIt() async throws {
    let f = try await editorFixture()
    try await openA(f, "keep me")
    await f.files.remove("/p/api/a.go")
    try await f.dispatch("editor_refresh", origin: .ui)
    var t = await f.snapshot().tabs[0]
    #expect(t.text == "keep me" && t.diskState == .deleted)
    try await f.dispatch("editor_save", origin: .ui)
    t = await f.snapshot().tabs[0]
    #expect(await f.files.disk["/p/api/a.go"]?.text == "keep me" && t.diskState == .inSync)
}

@Test func anUnchangedMtimeChangesNothing() async throws {
    let f = try await editorFixture()
    try await openA(f)
    let before = await f.snapshot()
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot() == before)
}

@Test func refreshOfOneRootLeavesOtherRootsTabsUnread() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.files.put("/p/web/b.ts", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/web/b.ts")])
    let reads = await f.files.calls.count
    try await f.dispatch("editor_refresh", ["root": .string("/p/web")], origin: .ui)
    #expect(await f.files.calls.suffix(from: reads) == ["files_read /p/web/b.ts"])
}

@Test func savingOverAChangedOnDiskFileWritesTheBuffer() async throws {
    let f = try await editorFixture()
    try await openA(f)
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine")
    await f.files.put("/p/api/a.go", "theirs")
    try await f.dispatch("editor_refresh", origin: .ui)
    try await f.dispatch("editor_save", origin: .ui)
    #expect(await f.files.disk["/p/api/a.go"]?.text == "mine")
    #expect(await f.snapshot().tabs[0].diskState == .inSync)
}
```

Run: `cd app && ../scripts/swift-test.sh --filter EditorRefresh`
Expected: FAIL — `editor_refresh` not registered.

- [ ] **Step 2: Implement the rule and the action**

In `EditorActions.swift` (top level):

```swift
/// What a tab becomes after re-reading its file (spec, Data flow: disk changes). `read` is the tab
/// a fresh `files_read` made. The operator's cursor, scroll, language and view are always kept.
func editorAfterDiskRead(_ tab: EditorTab, read: EditorTab) -> EditorTab {
    var t = tab
    if read.diskState == .deleted {
        t.diskState = .deleted
        return t
    }
    if read.mtime == tab.mtime && tab.diskState != .deleted { return tab }
    t.mtime = read.mtime
    t.readOnly = read.readOnly
    t.notice = read.notice ?? (tab.notice == nil ? nil : tab.notice)
    if read.text == tab.text {
        t.savedText = read.text
        t.diskState = .inSync
    } else if !tab.dirty {
        t.text = read.text
        t.savedText = read.text
        t.edits += 1
        t.diskState = .inSync
    } else {
        t.diskState = .changedOnDisk
    }
    return t
}
```

Inside `registerEditorActions`, after `editor_reload`:

```swift
    await registry.register(Action(
        name: "editor_refresh",
        description: "Re-read an editor pane's open files (under root, if given) from disk: a tab with no "
            + "unsaved edits reloads in place; one with edits keeps them and is marked changed on disk; a "
            + "missing file is marked deleted. The file watcher dispatches this.",
        kind: .read, audience: .agentReachable,
        schema: schema(["root": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_refresh")
            let only = optionalString(params, "root")
            let tabs = await panes.editorSnapshot(paneId: pane).tabs
            var reads: [String: EditorTab] = [:]
            for tab in tabs {
                guard case .file(let path, let r) = tab.subject, only == nil || r == only else { continue }
                if let fresh = try? await read(path, action: "editor_refresh") { reads[path] = fresh }
            }
            await panes.updateEditor(paneId: pane) { s in
                for i in s.tabs.indices {
                    guard let p = s.tabs[i].path, let fresh = reads[p] else { continue }
                    s.tabs[i] = editorAfterDiskRead(s.tabs[i], read: fresh)
                }
            }
            return await reply(pane)
        }))
```

`editor_save` already passes `create: true` for a `.deleted` tab (Task 4). Run:
`cd app && ../scripts/swift-test.sh --filter 'EditorRefresh|EditorActions'` — Expected: PASS.

- [ ] **Step 3: Write the failing window test** (`WindowModelEditorTests.swift`)

Model it on `WindowModelGitTests.theWatcherStartsWithAGitPaneAndAProjectAndStopsWithTheLastPane` and
its `gitWindow()` helper (read `WindowModelGitTests.swift` for the fake watcher type and how the window
is built with `rootWatcher:`). The editor test:

```swift
@Suite @MainActor struct WindowModelEditorTests {
    @Test func theEditorWatcherStartsWithAnEditorPaneAndStopsWithTheLast() async throws {
        let (model, watcher) = await editorWindow()   // as gitWindow(), passing editorRootWatcher:
        await model.refreshContext()
        #expect(await watcher.events.isEmpty)
        await model.openPane(kind: "editor")
        #expect(await watcher.events == ["watch /p/api,/p/portal 0.3 seconds"])
        let id = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.closePane(id: id)
        #expect(await watcher.events.last == "stop")
    }
}
```

Use the exact event strings the git test's fake watcher emits.

Run: `cd app && ../scripts/swift-test.sh --filter WindowModelEditor` — Expected: FAIL.

- [ ] **Step 4: Implement the watcher in `WindowModel`**

- Init: add `editorRootWatcher: (any RootWatcher)? = nil` beside `rootWatcher`, everywhere
  `rootWatcher` is threaded (all `init` overloads and `WindowSession`'s call that passes
  `wiring.rootWatcher`), and store `private let editorWatcher: GitRootWatcher?` =
  `editorRootWatcher.map { GitRootWatcher(watcher: $0) }`. (`GitRootWatcher` is the chained
  sync wrapper; it has nothing git-specific.)
- Add, beside `syncGitWatcher()`:

```swift
    /// The editor's watch: the project's roots while an editor pane is open (3b-i). A change
    /// dispatches `editor_refresh` for that root in every editor pane.
    private func syncEditorWatcher() async {
        guard let editorWatcher else { return }
        let roots = gitRootPaths
        let hasEditor = layoutSnapshot.panes.contains { PaneKinds.is($0.kind, EditorPaneKind.self) }
        let changed: @Sendable (String) async -> Void = { [weak self] root in await self?.editorRootChanged(root) }
        _ = await editorWatcher.sync(to: hasEditor ? roots : [], changed: changed)
    }

    private func editorRootChanged(_ root: String) async {
        guard gitRootPaths.contains(root) else { return }
        for pane in layoutSnapshot.panes where PaneKinds.is(pane.kind, EditorPaneKind.self) {
            _ = try? await registry.dispatch(
                name: "editor_refresh", params: .object(["pane": .string(pane.id), "root": .string(root)]),
                origin: .ui, environment: environment, confirmation: nil)
        }
        await refreshPanes()
    }
```

- Call `await syncEditorWatcher()` right after each of the four `await syncGitWatcher()` calls.
- `AppWiring.swift`: `WakilWiring` gains `editorRootWatcher: FSEventsRootWatcher()`; pass it where
  `rootWatcher` is passed to the window.

The `GitWatcher` path filter (`.git/objects`, locks) is inside `FSEventsRootWatcher`; an editor wake on a
`.git`-only change costs one `files_read` per open tab and changes nothing (mtime unchanged) — acceptable.

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelEditor|WindowModelGit'` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorActions.swift app/Sources/WakilKit/App/WindowModel.swift \
  app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/EditorRefreshTests.swift \
  app/Tests/WakilKitTests/WindowModelEditorTests.swift
git commit -m "Editor: disk changes — clean reloads, dirty is marked, deleted keeps its text (3b-i PR 5)"
```

---

### Task 6: Files in ⌘P (PR 6)

**Files:**
- Modify: `app/Sources/WakilKit/Command/PaletteEntry.swift` (`PaletteAction.openInEditor`)
- Modify: `app/Sources/WakilKit/Command/PaletteSources.swift` (`FilesSource`, `PaletteClients.files`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`paletteOpenSources`, `performPaletteAction`, palette clients)
- Test: `app/Tests/WakilKitTests/PaletteFilesSourceTests.swift`, `WindowModelPaletteTests.swift`

**Interfaces:**
- Produces: `case openInEditor(path: String)` on `PaletteAction`;
  `public struct FilesSource: PaletteSource` (`id "files"`, group `.resources`,
  `init(files: any ToolCaller, roots: @escaping @Sendable () async -> [String])`);
  `PaletteClients.files: (any ToolCaller)?`.

- [ ] **Step 1: Write the failing source tests**

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func filesSourceListsEveryRootsFilesAsOpenInEditorRows() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["internal/wakilcore/config.go", "main.go"])
    await files.setListing("/p/web", ["src/app.ts"])
    let rows = await FilesSource(files: files, roots: { ["/p/api", "/p/web"] }).entries()
    #expect(rows.map(\.title) == ["config.go", "main.go", "app.ts"])
    #expect(rows[0].subtitle == "internal/wakilcore · api")
    #expect(rows[0].kindLabel == "file" && rows[0].group == .resources)
    #expect(rows[0].action == .openInEditor(path: "/p/api/internal/wakilcore/config.go"))
}

@Test func aRootThatFailsToListIsOneErrorRowAndHidesNoOtherRoot() async {
    let files = FakeFiles()
    await files.setListing("/p/web", ["src/app.ts"])
    await files.setListError("/p/api", "root /p/api is not readable")
    let rows = await FilesSource(files: files, roots: { ["/p/api", "/p/web"] }).entries()
    #expect(rows.contains { $0.isError && $0.title.contains("/p/api is not readable") })
    #expect(rows.contains { $0.title == "app.ts" })
}
```

Add `setListing` and `setListError` to `FakeFiles` (a list error answers `isError` with the text).

Run: `cd app && ../scripts/swift-test.sh --filter PaletteFilesSource` — Expected: FAIL.

- [ ] **Step 2: Implement `FilesSource`** (in `PaletteSources.swift`, after `ChangedFilesSource`)

```swift
/// Every file in the project's roots (3b-i), one row each — `config.go · internal/wakilcore · api` —
/// opening in an editor pane. The palette spec left this seam for it: *"All files in a root join when
/// the editor ships, through the same source seam."* A root that cannot be listed is one error row,
/// and every other root still lists (rule 8).
public struct FilesSource: PaletteSource {
    public let id = "files"
    public let group = PaletteGroup.resources
    private let files: any ToolCaller
    private let roots: @Sendable () async -> [String]

    public init(files: any ToolCaller, roots: @escaping @Sendable () async -> [String]) {
        self.files = files
        self.roots = roots
    }

    public func entries() async -> [PaletteEntry] {
        var rows: [PaletteEntry] = []
        for root in await roots() {
            let rootName = (root as NSString).lastPathComponent
            let result: JSONValue
            do {
                result = try await files.callTool(name: "files_list", arguments: .object(["root": .string(root)]),
                                                  timeout: MCPClient.readReplyTimeout)
            } catch {
                rows.append(errorRow(root, String(describing: error)))
                continue
            }
            guard case .object(let obj) = result else { continue }
            if case .bool(true)? = obj["isError"] {
                rows.append(errorRow(root, mcpErrorText(from: obj) ?? "files_list failed for \(root)"))
                continue
            }
            guard case .object(let content)? = obj["structuredContent"], case .array(let list)? = content["files"] else { continue }
            for case .string(let rel) in list {
                let folder = (rel as NSString).deletingLastPathComponent
                rows.append(PaletteEntry(
                    id: "editorfile:\(root)/\(rel)", group: group, title: (rel as NSString).lastPathComponent,
                    subtitle: folder.isEmpty ? rootName : "\(folder) · \(rootName)", kindLabel: "file",
                    verb: "open", action: .openInEditor(path: "\(root)/\(rel)")))
            }
        }
        return rows
    }

    private func errorRow(_ root: String, _ text: String) -> PaletteEntry {
        PaletteEntry(id: "editorfile-error:\(root)", group: group, title: text, subtitle: "files", kindLabel: "file",
                     verb: "open", action: .focusPane(id: ""), isError: true)
    }
}
```

Add `public var files: (any ToolCaller)?` to `PaletteClients` (init param defaulted to `nil`) and
`case openInEditor(path: String)` to `PaletteAction` with the doc *"A project file: the window opens it
in the focused or first editor pane, or a new one (`editor_open` with no pane)."*. Update the `id` doc
list in `PaletteSource` to include `"files"`.

Run: `cd app && ../scripts/swift-test.sh --filter PaletteFilesSource` — Expected: PASS.

- [ ] **Step 3: Wire it into the window, file rows first when an editor is focused**

Write the failing test in `WindowModelPaletteTests.swift` following its existing helper for building a
window with palette clients (read the file first); the assertion:

```swift
    @Test func fileRowsComeFirstInResourcesWhenAnEditorIsFocused() async throws {
        // build the window with paletteClients: PaletteClients(git: fakeGit, files: fakeFiles)
        // with fakeFiles listing "/p/api" -> ["a.go"] and fakeGit reporting a changed file.
        // Open an editor pane (focused), open ⌘P, and read the resources rows' kind labels in order.
        // #expect(resourceKinds.first == "file")
        // Then focus a non-editor pane and reopen ⌘P: #expect(resourceKinds.first == "git")
    }
```

Write it fully against the file's real helpers; the two `#expect`s above are the assertions.

Implementation in `paletteOpenSources(tables:)`, replacing the `ChangedFilesSource` append:

```swift
        let changed = ChangedFilesSource(
            gitPanes: { [weak self] in await self?.paletteGitPanes() ?? [] },
            statusWithoutPane: { [weak self] in await self?.paletteGitStatusWithoutPane() ?? [] })
        let fileSource: FilesSource? = paletteClients.files.map { files in
            FilesSource(files: files, roots: { [weak self] in await self?.gitRootPaths ?? [] })
        }
        // An editor in focus puts the project's files first: sources keep their own order within a group.
        let editorFocused = layoutSnapshot.panes.first { $0.id == layoutSnapshot.focusedId }?.kind == "editor"
        if let fileSource, editorFocused { sources.append(fileSource) }
        sources.append(changed)
        if let fileSource, !editorFocused { sources.append(fileSource) }
```

In `performPaletteAction`, add:

```swift
        case .openInEditor(let path):
            let before = paneIds
            guard await dispatchLayout("editor_open", .object(["path": .string(path)])) != nil else {
                return paletteFailure(since: mark)
            }
            await refreshPanes()
            return await focusActedOn(since: before, named: focusedEditorPane(), mark: mark)
```

with a helper `private func focusedEditorPane() -> String?` answering the focused pane id if it is an
editor, else the first editor pane's id. Where the window's `paletteClients` are built (search
`PaletteClients(` in `WindowSession`/`AppWiring`), pass `files: wiring.filesClient`.

`gitRootPaths` is main-actor state; if the closure cannot read it, use the same root reader the
editor actions use (`GitRootsSource.current()`) via a stored closure.

Run: `cd app && ../scripts/swift-test.sh --filter 'Palette'` — Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/WakilKit/Command app/Sources/WakilKit/App app/Tests/WakilKitTests/PaletteFilesSourceTests.swift \
  app/Tests/WakilKitTests/WindowModelPaletteTests.swift app/Tests/WakilKitTests/EditorTestSupport.swift
git commit -m "⌘P lists the project's files and opens them in the editor, first when an editor is focused (3b-i PR 6)"
```

---

### Task 7: The `EditorRenderer` seam and the render decision (PR 7)

Pure, tested in WakilKit, so the WakilApp view (no test target) only applies what it is told.

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorRenderer.swift`
- Test: `app/Tests/WakilKitTests/EditorRendererTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor public protocol EditorRenderer: AnyObject {
    /// Show `tab`'s model, creating it with `text` if this key is new; switching keeps each model's undo.
    func showModel(key: String, text: String, language: String, readOnly: Bool)
    func setLanguage(key: String, language: String)
    func setReadOnly(key: String, readOnly: Bool)
    /// Replace a model's whole text (a reload) — keeps cursor and scroll where they fit.
    func resetText(key: String, text: String)
    /// Apply one edit as an undoable step (an agent edit).
    func applyEdit(key: String, range: EditorRange, text: String)
    func reveal(key: String, cursor: EditorPosition, selection: EditorRange?)
    func setScrollTop(key: String, top: Double)
    func disposeModel(key: String)
    func focus()
}

public struct EditorRendered: Sendable, Equatable {   // what the renderer was last told, per tab key
    public var text: String
    public var language: String
    public var readOnly: Bool
    public var agentSerial: Int
    public var cursor: EditorPosition
    public var selection: EditorRange?
}

public enum EditorRenderStep: Sendable, Equatable {
    case show(key: String, text: String, language: String, readOnly: Bool)
    case language(key: String, String)
    case readOnly(key: String, Bool)
    case reset(key: String, text: String)
    case edit(key: String, range: EditorRange, text: String)
    case reveal(key: String, cursor: EditorPosition, selection: EditorRange?)
    case scroll(key: String, top: Double)
    case dispose(key: String)
}

public func editorTabKey(_ tab: EditorTab) -> String   // "file:<path>" or "scratch:<n>"
public func editorRenderSteps(rendered: [String: EditorRendered], active: String?, snapshot: EditorSnapshot,
                              firstShow: Bool) -> [EditorRenderStep]
public func editorRenderedAfter(_ steps: [EditorRenderStep], rendered: [String: EditorRendered],
                                snapshot: EditorSnapshot) -> [String: EditorRendered]
@MainActor public func editorApply(_ steps: [EditorRenderStep], to renderer: any EditorRenderer)
```

The decision rules:
- A tab key the renderer has not seen → `.show`, then `.reveal` of the stored cursor and `.scroll`
  of the stored `scrollTop` (a restored tab lands where it was).
- The active tab switched → `.show` of the new key (no reveal: Monaco keeps each model's view).
- Snapshot text == rendered text → no text step (the operator's own typing round-trips here: the
  store got it from Monaco, so telling Monaco again would reset the cursor).
- Text differs and `lastAgentEdit.serial` > rendered `agentSerial`, and applying that edit to the
  rendered text gives the snapshot text → `.edit` (undoable; the operator's cursor stays).
- Text differs otherwise (a reload, a disk change) → `.reset`.
- Cursor/selection differ from rendered and the change did not come from the view (the view writes
  its reports into `rendered` when it sends them, see Task 8) → `.reveal` (an agent `editor_goto`).
- Language / readOnly differ → their steps.
- A rendered key with no tab → `.dispose`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

private func tab(_ path: String, _ text: String) -> EditorTab {
    .file(path: path, root: "/p", text: text, mtime: 1, language: "go")
}
private func rendered(_ t: EditorTab) -> EditorRendered {
    EditorRendered(text: t.text, language: t.language, readOnly: t.readOnly,
                   agentSerial: t.lastAgentEdit?.serial ?? 0, cursor: t.cursor, selection: t.selection)
}

@Test func aNewTabIsShownRevealedAndScrolledToWhereItWas() {
    var a = tab("/p/a.go", "x"); a.cursor = EditorPosition(line: 4, column: 1); a.scrollTop = 80
    let s = EditorSnapshot(tabs: [a], active: 0)
    #expect(editorRenderSteps(rendered: [:], active: nil, snapshot: s, firstShow: true) == [
        .show(key: "file:/p/a.go", text: "x", language: "go", readOnly: false),
        .reveal(key: "file:/p/a.go", cursor: EditorPosition(line: 4, column: 1), selection: nil),
        .scroll(key: "file:/p/a.go", top: 80),
    ])
}

@Test func theOperatorsOwnTypingRoundTripsToNothing() {
    var a = tab("/p/a.go", "x")
    let r = ["file:/p/a.go": rendered(a)]
    a.text = "xy"; a.edits = 1
    var seen = r; seen["file:/p/a.go"]!.text = "xy"   // the view recorded what it sent
    #expect(editorRenderSteps(rendered: seen, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0), firstShow: false) == [])
}

@Test func renderUpdateForAnAgentEditIsAnEditNotAReset() {
    var a = tab("/p/a.go", "if x {}")
    let r = ["file:/p/a.go": rendered(a)]
    let edit = EditorRange(start: EditorPosition(line: 1, column: 4), end: EditorPosition(line: 1, column: 5))
    a.text = "if y {}"; a.lastAgentEdit = EditorAgentEdit(serial: 1, range: edit, text: "y")
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0), firstShow: false)
        == [.edit(key: "file:/p/a.go", range: edit, text: "y")])
}

@Test func anAgentEditOnTextTheRendererHasNotCaughtUpWithIsAReset() {
    var a = tab("/p/a.go", "abc")
    let r = ["file:/p/a.go": rendered(a)]
    a.text = "Xbcdef"   // operator typed "def" (not yet reported) and the agent replaced 1:1-1:2
    a.lastAgentEdit = EditorAgentEdit(serial: 1, range: EditorRange(start: EditorPosition(line: 1, column: 1), end: EditorPosition(line: 1, column: 2)), text: "X")
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0), firstShow: false)
        == [.reset(key: "file:/p/a.go", text: "Xbcdef")])
}

@Test func aReloadIsAReset() {
    var a = tab("/p/a.go", "old")
    let r = ["file:/p/a.go": rendered(a)]
    a.text = "new"; a.savedText = "new"
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0), firstShow: false)
        == [.reset(key: "file:/p/a.go", text: "new")])
}

@Test func anAgentGotoIsARevealAndAClosedTabIsDisposed() {
    var a = tab("/p/a.go", "x\ny")
    let b = tab("/p/b.go", "b")
    let r = ["file:/p/a.go": rendered(a), "file:/p/b.go": rendered(b)]
    a.cursor = EditorPosition(line: 2, column: 1)
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0), firstShow: false) == [
        .reveal(key: "file:/p/a.go", cursor: EditorPosition(line: 2, column: 1), selection: nil),
        .dispose(key: "file:/p/b.go"),
    ])
}

@Test func switchingTabsShowsTheOtherModelWithoutRevealing() {
    let a = tab("/p/a.go", "a"), b = tab("/p/b.go", "b")
    let r = ["file:/p/a.go": rendered(a), "file:/p/b.go": rendered(b)]
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a, b], active: 1), firstShow: false)
        == [.show(key: "file:/p/b.go", text: "b", language: "go", readOnly: false)])
}
```

Run: `cd app && ../scripts/swift-test.sh --filter EditorRenderer` — Expected: FAIL.

- [ ] **Step 2: Implement `EditorRenderer.swift`** with the protocol and types from **Interfaces**, and:

```swift
public func editorTabKey(_ tab: EditorTab) -> String {
    switch tab.subject {
    case .file(let path, _): "file:\(path)"
    case .scratch(let n): "scratch:\(n)"
    }
}

public func editorRenderSteps(rendered: [String: EditorRendered], active: String?, snapshot: EditorSnapshot,
                              firstShow: Bool) -> [EditorRenderStep] {
    var steps: [EditorRenderStep] = []
    let keys = Set(snapshot.tabs.map(editorTabKey))
    if let i = snapshot.active, i < snapshot.tabs.count {
        let t = snapshot.tabs[i], key = editorTabKey(t)
        if let r = rendered[key] {
            if key != active { steps.append(.show(key: key, text: t.text, language: t.language, readOnly: t.readOnly)) }
            if t.text != r.text {
                if let e = t.lastAgentEdit, e.serial > r.agentSerial, editorReplacing(r.text, e.range, with: e.text) == t.text {
                    steps.append(.edit(key: key, range: e.range, text: e.text))
                } else {
                    steps.append(.reset(key: key, text: t.text))
                }
            }
            if t.language != r.language { steps.append(.language(key: key, t.language)) }
            if t.readOnly != r.readOnly { steps.append(.readOnly(key: key, t.readOnly)) }
            if t.cursor != r.cursor || t.selection != r.selection {
                steps.append(.reveal(key: key, cursor: t.cursor, selection: t.selection))
            }
        } else {
            steps.append(.show(key: key, text: t.text, language: t.language, readOnly: t.readOnly))
            steps.append(.reveal(key: key, cursor: t.cursor, selection: t.selection))
            steps.append(.scroll(key: key, top: t.scrollTop))
        }
    }
    for key in rendered.keys.sorted() where !keys.contains(key) { steps.append(.dispose(key: key)) }
    return steps
}

/// What the renderer holds after `steps`: every shown key at the snapshot's state.
public func editorRenderedAfter(_ steps: [EditorRenderStep], rendered: [String: EditorRendered],
                                snapshot: EditorSnapshot) -> [String: EditorRendered] {
    var out = rendered
    for step in steps { if case .dispose(let key) = step { out[key] = nil } }
    if let i = snapshot.active, i < snapshot.tabs.count {
        let t = snapshot.tabs[i]
        out[editorTabKey(t)] = EditorRendered(text: t.text, language: t.language, readOnly: t.readOnly,
                                              agentSerial: t.lastAgentEdit?.serial ?? 0, cursor: t.cursor,
                                              selection: t.selection)
    }
    return out
}

@MainActor public func editorApply(_ steps: [EditorRenderStep], to renderer: any EditorRenderer) {
    for step in steps {
        switch step {
        case .show(let key, let text, let language, let readOnly): renderer.showModel(key: key, text: text, language: language, readOnly: readOnly)
        case .language(let key, let language): renderer.setLanguage(key: key, language: language)
        case .readOnly(let key, let on): renderer.setReadOnly(key: key, readOnly: on)
        case .reset(let key, let text): renderer.resetText(key: key, text: text)
        case .edit(let key, let range, let text): renderer.applyEdit(key: key, range: range, text: text)
        case .reveal(let key, let cursor, let selection): renderer.reveal(key: key, cursor: cursor, selection: selection)
        case .scroll(let key, let top): renderer.setScrollTop(key: key, top: top)
        case .dispose(let key): renderer.disposeModel(key: key)
        }
    }
}
```

(`firstShow` is accepted for the view's first render; it changes nothing above — remove the parameter
if no test needs it, and from the tests.)

Run: `cd app && ../scripts/swift-test.sh --filter EditorRenderer` — Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorRenderer.swift app/Tests/WakilKitTests/EditorRendererTests.swift
git commit -m "EditorRenderer seam: what Monaco is told for each snapshot (3b-i PR 7)"
```

---

### Task 8: The pane — Monaco editor mode, the view, ⌘T ⌘S ⌘W (PR 8)

`WakilApp` has no test target: logic stays in WakilKit (Tasks 3–7, and the `WindowModel` methods below,
which are tested); this task draws and wires.

**Files:**
- Modify: `app/Sources/WakilApp/monaco-host.html` (editor mode)
- Create: `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `app/Sources/WakilApp/EditorPane.swift`
- Modify: `app/Sources/WakilApp/Canvas.swift` (`case "editor"`), `app/Sources/WakilApp/AppScene.swift` (menu commands)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`newScratch()`, `saveFocusedEditor()`, `closeFocusedTabOrPane()`, `editorSaveAsRequest`)
- Test: `app/Tests/WakilKitTests/WindowModelEditorTests.swift` (extend)

**Interfaces:**
- Produces (`WindowModel`, tested): `func newScratch() async` (⌘T), `func saveFocusedEditor() async`
  (⌘S; on a scratch tab sets `editorSaveAsRequest = paneId` instead of saving),
  `func closeFocusedTabOrPane() async` (⌘W; a dirty tab sets `unsavedPrompt`, Task 9),
  `public private(set) var editorSaveAsRequest: String?`, `func saveScratch(pane:as:) async -> String?`
  (answers the failure text or nil), `func editorBufferDidChange(pane:tab:text:)`,
  `func editorViewDidReport(pane:tab:cursor:selection:visibleRange:scrollTop:)` (store + layout persist).

- [ ] **Step 1: Write the failing window tests** (append to `WindowModelEditorTests`)

```swift
    @Test func commandTOpensAScratchTabInTheFocusedEditorOrANewEditorPane() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(model.editor(pane.id)?.tabs.map(\.subject) == [.scratch(number: 1)])
        await model.newScratch()
        #expect(model.layoutSnapshot.panes.filter { $0.kind == "editor" }.count == 1)
        #expect(model.editor(pane.id)?.tabs.count == 2)
    }

    @Test func commandSOnAScratchTabAsksForAPathInsteadOfSaving() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        await model.saveFocusedEditor()
        #expect(model.editorSaveAsRequest == model.layoutSnapshot.focusedId)
    }

    @Test func commandWClosesTheActiveTabThenThePane() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.newScratch()
        await model.closeFocusedTabOrPane()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" })
        #expect(model.editor(pane.id)?.tabs.isEmpty == true)
        await model.closeFocusedTabOrPane()
        #expect(!model.layoutSnapshot.panes.contains { $0.kind == "editor" })
    }

    @Test func cancellingASaveInFlightLeavesTheTabDirty() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        _ = await model.dispatch("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b")
        await files.setSlowWrite(true)
        let save = Task { await model.saveFocusedEditor() }
        while await !model.panes.editorSnapshot(paneId: pane).tabs[0].saving { await Task.yield() }
        model.cancelSave(pane: pane)
        await files.releaseWrite()
        await save.value
        let t = await model.panes.editorSnapshot(paneId: pane).tabs[0]
        #expect(t.dirty && !t.saving)
    }

    @Test func commandWOnANonEditorPaneClosesThePaneAsBefore() async throws {
        let (model, _) = await editorWindow()
        await model.refreshContext()
        await model.openPane(kind: "git")
        await model.closeFocusedTabOrPane()
        #expect(model.layoutSnapshot.panes.isEmpty)
    }
```

`editorWindow()` must pass a `FakeFiles` as the files client into the window's registry (build the
registry with `registerEditorActions(... files: FakeFiles() ...)` the way `gitWindow()` registers git);
`editorWindowWithFiles()` is the same, returning the `FakeFiles` too. If `model.panes` is not visible to
tests, read the tab through `model.editor(pane)` after `await model.refreshPanes()`.

Run: `cd app && ../scripts/swift-test.sh --filter WindowModelEditor` — Expected: FAIL.

- [ ] **Step 2: Implement the `WindowModel` methods**

```swift
    // MARK: Editor (3b-i)

    /// The pane ⌘T, ⌘S and ⌘W act on: the focused pane if it is an editor.
    private var focusedEditor: String? {
        guard let id = layoutSnapshot.focusedId,
              layoutSnapshot.panes.first(where: { $0.id == id })?.kind == "editor" else { return nil }
        return id
    }

    /// The scratch tab ⌘S could not save without a path: the pane whose path field should show.
    public private(set) var editorSaveAsRequest: String?

    /// ⌘T: a scratch tab in the focused editor pane, else the first, else a new one.
    public func newScratch() async {
        var params: [String: JSONValue] = [:]
        if let pane = focusedEditor { params["pane"] = .string(pane) }
        let before = paneIds
        guard let reply = await dispatch("editor_new_scratch", .object(params)) else { return }
        await refreshLayout()
        await refreshPanes()
        if let pane = optionalString(reply, "pane"), layoutSnapshot.focusedId != pane || !before.contains(pane) {
            await focusPane(id: pane)
        }
    }

    /// ⌘S in a focused editor pane. A scratch tab asks for a path (the pane draws its field).
    public func saveFocusedEditor() async {
        guard let pane = focusedEditor, let s = editor(pane), let i = s.active, i < s.tabs.count else { return }
        if s.tabs[i].isScratch {
            editorSaveAsRequest = pane
            return
        }
        let save = Task { _ = await self.dispatch("editor_save", .object(["pane": .string(pane)])) }
        editorSaves[pane] = save
        await save.value
        editorSaves[pane] = nil
        await refreshPanes()
    }

    /// The save ⌘S started in `pane`, while it runs (Rule 4: anything that waits can be cancelled).
    @ObservationIgnored private var editorSaves: [String: Task<Void, Never>] = [:]

    /// The saving tick's Cancel: the write is abandoned and the buffer stays dirty.
    public func cancelSave(pane: String) {
        editorSaves[pane]?.cancel()
    }

    /// The path field's Save. Answers the failure text, or nil and closes the field.
    public func saveScratch(pane: String, as path: String) async -> String? {
        let mark = statusWrites
        guard await dispatch("editor_save", .object(["pane": .string(pane), "as": .string(path)])) != nil else {
            return statusWrites != mark ? status : "editor_save failed"
        }
        editorSaveAsRequest = nil
        await refreshLayout()
        await refreshPanes()
        return nil
    }

    public func cancelSaveAs() { editorSaveAsRequest = nil }

    /// ⌘W: the active tab of a focused editor pane, else the pane, as before. A tab with unsaved
    /// edits asks first (`unsavedPrompt`, Task 9).
    public func closeFocusedTabOrPane() async {
        guard let id = layoutSnapshot.focusedId else { return }
        let s = focusedEditor.flatMap { editor($0) } ?? .empty
        guard let pane = focusedEditor, editorCloseTarget(tabs: s.tabs.count) == .tab, let i = s.active else {
            await closePane(id: id)
            return
        }
        if s.tabs[i].dirty {
            askUnsaved(.closeTab(pane: pane, tab: i), tabs: [s.tabs[i]])   // Task 9
            return
        }
        _ = await dispatch("editor_close", .object(["pane": .string(pane), "discard": .bool(true)]))
        await refreshLayout()
        await refreshPanes()
    }

    /// The operator's typing (the one non-action path) — straight to the store, then the cell.
    public func editorBufferDidChange(pane: String, tab: Int, text: String) async {
        await panes.editorBufferDidChange(paneId: pane, tab: tab, text: text)
        await refreshPane(pane)
    }

    /// Cursor, selection, visible lines and scroll from Monaco; persisted with the saved tabs.
    public func editorViewDidReport(pane: String, tab: Int, cursor: EditorPosition, selection: EditorRange?,
                                    visibleRange: ClosedRange<Int>?, scrollTop: Double) async {
        await panes.editorViewDidReport(paneId: pane, tab: tab, cursor: cursor, selection: selection,
                                        visibleRange: visibleRange, scrollTop: scrollTop)
        await layout.setEditorTabs(id: pane, to: editorSavedTabs(await panes.editorSnapshot(paneId: pane)))
        await persistLayout()
    }
```

Use the window's real names: `dispatch(_:_:)` (answers the result or nil and writes `status`),
`statusWrites`, `refreshLayout()`, `refreshPanes()`, and a single-pane refresh if one exists (search
`func refreshPane` / how `refreshTerminal` updates one cell); if there is none, call `refreshPanes()`.
The `layout` property may be named `layoutStore` — check. Until Task 9 lands, stub `askUnsaved` as a
private method that sets nothing and returns (Task 9 replaces it); the dirty-tab path is tested there.

Run: `cd app && ../scripts/swift-test.sh --filter WindowModelEditor` — Expected: PASS.

- [ ] **Step 3: The host page's editor mode** (`monaco-host.html`)

Add, inside the `require([...], function () {` body, before the diff editor is created, a branch on
`window.wakilMode === 'editor'` (set by a `WKUserScript`, the mechanism `--probe-monaco` already uses).
In editor mode the diff editor is not created; this runs instead and returns:

```js
    if (window.wakilMode === 'editor') {
      const post = function (m) { window.webkit.messageHandlers.wakil.postMessage(m); };
      const ed = monaco.editor.create(document.getElementById('d'), {
        theme: 'wakil', automaticLayout: true, minimap: { enabled: false },
        fontFamily: 'Menlo, monospace', fontSize: 12, model: null
      });
      const models = {};          // key -> model
      let current = null;         // key shown
      let applying = false;       // true while the app's own edit lands: not reported back as typing
      let typingTimer = null;
      function report() {
        if (!current) return;
        const pos = ed.getPosition(), sel = ed.getSelection(), vr = ed.getVisibleRanges();
        post({ type: 'view', key: current,
               cursor: pos ? { line: pos.lineNumber, column: pos.column } : { line: 1, column: 1 },
               selection: (sel && !sel.isEmpty()) ? { start: { line: sel.startLineNumber, column: sel.startColumn },
                                                      end: { line: sel.endLineNumber, column: sel.endColumn } } : null,
               visible: vr.length ? { first: vr[0].startLineNumber, last: vr[vr.length - 1].endLineNumber } : null,
               scrollTop: ed.getScrollTop() });
      }
      ed.onDidChangeModelContent(function () {
        if (applying || !current) return;
        if (typingTimer !== null) cancelAnimationFrame(typingTimer);
        const key = current;
        typingTimer = requestAnimationFrame(function () {
          typingTimer = null;
          if (models[key]) post({ type: 'text', key: key, text: models[key].getValue() });
        });
      });
      ed.onDidChangeCursorSelection(report);
      ed.onDidScrollChange(function (e) { if (e.scrollTopChanged) report(); });
      window.wakilShowModel = function (key, text, language, readOnly) {
        if (!models[key]) models[key] = monaco.editor.createModel(text, language);
        current = key;
        ed.setModel(models[key]);
        ed.updateOptions({ readOnly: readOnly });
        report();
      };
      window.wakilSetLanguage = function (key, language) { if (models[key]) monaco.editor.setModelLanguage(models[key], language); };
      window.wakilSetReadOnly = function (key, on) { if (key === current) ed.updateOptions({ readOnly: on }); };
      window.wakilResetText = function (key, text) {
        const m = models[key]; if (!m) return;
        applying = true;
        const pos = key === current ? ed.getPosition() : null, top = key === current ? ed.getScrollTop() : 0;
        m.pushEditOperations([], [{ range: m.getFullModelRange(), text: text }], function () { return null; });
        if (pos) { ed.setPosition(pos); ed.setScrollTop(top); }
        applying = false;
      };
      window.wakilApplyEdit = function (key, sl, sc, el, ec, text) {
        const m = models[key]; if (!m) return;
        applying = true;
        m.pushEditOperations([], [{ range: new monaco.Range(sl, sc, el, ec), text: text }], function () { return null; });
        applying = false;
      };
      window.wakilReveal = function (key, line, column, sel) {
        if (key !== current) return;
        if (sel) ed.setSelection(new monaco.Range(sel[0], sel[1], sel[2], sel[3])); else ed.setPosition({ lineNumber: line, column: column });
        ed.revealLineInCenterIfOutsideViewport(line);
      };
      window.wakilSetScrollTop = function (key, top) { if (key === current) ed.setScrollTop(top); };
      window.wakilDispose = function (key) { if (models[key]) { models[key].dispose(); delete models[key]; } if (current === key) current = null; };
      window.wakilFocus = function () { ed.focus(); };
      // ⌘S, ⌘T, ⌘W, ⌘P and ⌘K are the window's menu commands: un-prevented, so WebKit hands them back.
      window.addEventListener('keydown', function (e) {
        if (e.metaKey && !e.ctrlKey && !e.altKey && ['s', 't', 'w', 'p', 'k'].indexOf(e.key) >= 0) { e.stopPropagation(); }
      }, true);
      post({ type: 'ready' });
      return;
    }
```

The `defineTheme` call stays before the branch so both modes use it.

- [ ] **Step 4: `MonacoEditorRenderer.swift`** — the `EditorRenderer` conformance

Mirror `MonacoDiffRenderer` (network block required, weak message proxy, `run(_:)` queue until `ready`,
`tearDown`), with a `WKUserScript` `window.wakilMode = 'editor';` injected at document start, and:

```swift
    var onText: ((String, String) -> Void)?                                         // key, text
    var onView: ((String, EditorPosition, EditorRange?, ClosedRange<Int>?, Double) -> Void)?

    func showModel(key: String, text: String, language: String, readOnly: Bool) {
        run("wakilShowModel(\([key, text, language].map(Self.jsString).joined(separator: ",")),\(readOnly))")
    }
    func setLanguage(key: String, language: String) { run("wakilSetLanguage(\(Self.jsString(key)),\(Self.jsString(language)))") }
    func setReadOnly(key: String, readOnly: Bool) { run("wakilSetReadOnly(\(Self.jsString(key)),\(readOnly))") }
    func resetText(key: String, text: String) { run("wakilResetText(\(Self.jsString(key)),\(Self.jsString(text)))") }
    func applyEdit(key: String, range r: EditorRange, text: String) {
        run("wakilApplyEdit(\(Self.jsString(key)),\(r.start.line),\(r.start.column),\(r.end.line),\(r.end.column),\(Self.jsString(text)))")
    }
    func reveal(key: String, cursor: EditorPosition, selection: EditorRange?) {
        let sel = selection.map { "[\($0.start.line),\($0.start.column),\($0.end.line),\($0.end.column)]" } ?? "null"
        run("wakilReveal(\(Self.jsString(key)),\(cursor.line),\(cursor.column),\(sel))")
    }
    func setScrollTop(key: String, top: Double) { run("wakilSetScrollTop(\(Self.jsString(key)),\(top.isFinite ? top : 0))") }
    func disposeModel(key: String) { run("wakilDispose(\(Self.jsString(key)))") }
    func focus() { run("wakilFocus()") }
```

`receive` handles `ready`, `log`, `text` (→ `onText`) and `view` (decode cursor, selection, visible,
scrollTop → `onView`). Reuse `MonacoDiffRenderer.jsString` and `compileNetworkBlock()` (make them
`static` internal if they are private).

- [ ] **Step 5: `EditorPane.swift`** — the view

A `View` taking `snapshot: EditorSnapshot`, `pane: Pane`, and closures `dispatch(name, params) async`,
`bufferChanged(tab, text) async`, `viewReported(tab, cursor, selection, visible, scroll) async`,
`saveAs(path) async -> String?`, `cancelSaveAs()`, plus `saveAsRequested: Bool`, `firstRoot: String`,
`isFocusedPane: Bool`. It draws, top to bottom:

1. **Tab strip** (the `Editor.dc.html` `.tab` treatment: 30 pt, violet tick on the active tab, mono 11.5 pt
   title from `editorTabTitles`, a dirty dot, an amber *changed on disk* or muted *deleted* mark, the
   *saving* busy tick when `saving`, beside it a **Cancel** control (`editor.saving.cancel`) calling
   `model.cancelSave(pane:)` — Rule 4). Click → `dispatch("editor_focus_tab", ["index": …])`.
2. **The notice line** when the active tab has `notice` (whole text, wraps, never truncated — Rule 8).
3. **The disk-changed line** when the active tab is `.changedOnDisk`: *"`name` changed on disk"* with
   **Reload** (`editor_reload`) and **Compare** (a diff view in the pane, in place of the editor until
   Esc or **Close**, hosting a `MonacoDiffRenderer` showing disk text against buffer — the spec says "a
   diff tab"; a view in the pane keeps `EditorTab` free of a third subject and reads the same; the disk text comes from `files_read` via a new
   `WindowModel.editorDiskText(pane:path:) async -> String?` that calls the files client directly — a
   read, no state change).
4. **The save-as field** when `saveAsRequested`: a `TextField` prefilled with `firstRoot + "/"`, focused
   on appear (Rule 3), keeps its text when focus leaves (Rule 2), Return or **Save** calls `saveAs`, the
   failure text shows under it whole, Esc or **Cancel** calls `cancelSaveAs`.
5. **The Monaco host**: an `EditorHost` (`@Observable` class in `@State`, like `GitDiffHost`) that makes
   one `MonacoEditorRenderer` per pane, holds `rendered: [String: EditorRendered]` and `active: String?`,
   and on every snapshot change runs:

```swift
let steps = editorRenderSteps(rendered: host.rendered, active: host.active, snapshot: snapshot, firstShow: false)
editorApply(steps, to: renderer)
host.rendered = editorRenderedAfter(steps, rendered: host.rendered, snapshot: snapshot)
host.active = snapshot.active.flatMap { $0 < snapshot.tabs.count ? editorTabKey(snapshot.tabs[$0]) : nil }
```

   and wires `renderer.onText = { key, text in host.rendered[key]?.text = text; Task { await bufferChanged(index(of: key), text) } }`
   and `renderer.onView = { key, cursor, sel, visible, top in host.rendered[key]?.cursor = cursor; host.rendered[key]?.selection = sel; Task { await viewReported(index(of: key), cursor, sel, visible, top) } }`
   — writing into `rendered` **before** the store round-trip is what makes the operator's own typing and
   cursor moves render as nothing (Task 7's rule).
6. **Empty state** (no tabs): one muted line, *"⌘P to open a file · ⌘T for a scratch tab"*.

Accessibility identifiers for the e2e auditor: `editor.tab.<index>`, `editor.notice`, `editor.diskChanged`,
`editor.reload`, `editor.compare`, `editor.saveAs.field`, `editor.saveAs.save`, `editor.saveAs.cancel`,
`editor.saving`, `editor.empty`.

- [ ] **Step 6: Canvas arm and menu commands**

`Canvas.swift`, after `case "git":`:

```swift
            case "editor":
                // 3b-i. Clicks are `editor_*` actions through the window's dispatch; typing and view
                // reports take the one non-action path (`editorBufferDidChange`).
                EditorPane(
                    snapshot: model.editor(pane.id) ?? .empty, pane: pane,
                    dispatch: { name, params in
                        var withPane = params
                        withPane["pane"] = .string(pane.id)
                        await model.dispatchFromSurface(name, .object(withPane))
                    },
                    bufferChanged: { tab, text in await model.editorBufferDidChange(pane: pane.id, tab: tab, text: text) },
                    viewReported: { tab, cursor, sel, visible, top in
                        await model.editorViewDidReport(pane: pane.id, tab: tab, cursor: cursor, selection: sel,
                                                        visibleRange: visible, scrollTop: top)
                    },
                    saveAs: { path in await model.saveScratch(pane: pane.id, as: path) },
                    cancelSaveAs: { model.cancelSaveAs() },
                    saveAsRequested: model.editorSaveAsRequest == pane.id,
                    firstRoot: model.gitRootPaths.first ?? "",
                    isFocusedPane: model.layoutSnapshot.focusedId == pane.id)
```

`AppScene.swift`, in the `CommandGroup(after: .windowArrangement)`:
- *Close Pane* (⌘W) becomes `focusedPane { model, _ in await model.closeFocusedTabOrPane() }`, label
  unchanged.
- Add `Button("New Scratch Tab") { withModel { model in Task { await model.newScratch() } } }.keyboardShortcut("t", modifiers: .command)`.
- Add `Button("Save") { focusedPane { model, _ in await model.saveFocusedEditor() } }.keyboardShortcut("s", modifiers: .command)`.
  Update the comment listing the window's bound keys (⌘↩, ⌘W, ⌘⇧D, ⌘P, ⌘K, now ⌘T and ⌘S).

Check `withModel`'s closure type (sync or async) and match it.

- [ ] **Step 7: *Set language…* in ⌘K**

In `Command/CommandCatalog.swift`, add a catalog entry for the focused editor pane, *"Set language…"*,
whose input step is a choice among Monaco's languages (`editorLanguageChoices`: plaintext, sql, json,
go, typescript, javascript, php, yaml, markdown, shell, html, css, python, swift, ini, dockerfile, xml),
dispatching `editor_set_language {language}`. Follow an existing focused-pane `…` entry exactly (read
the file for one — the api pane's or the db pane's), and add a `CommandCatalogTests` case
`setLanguageIsOfferedOnlyForAFocusedEditor`.

- [ ] **Step 8: Build and run what can be run**

Run: `make build && cd app && swift build && ../scripts/swift-test.sh --filter 'Editor|Canvas|CommandCatalog'`
Expected: builds; PASS. Launch per the `run` skill / `driving-wakil-app-headlessly` memory only with the
operator's go-ahead (shared GUI rule) — the walk is the operator's.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/WakilApp app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "Editor pane: Monaco editor mode, tabs, save-as, disk line, ⌘T ⌘S ⌘W, Set language (3b-i PR 8)"
```

---

### Task 9: Unsaved work is never lost silently (PR 9)

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`unsavedPrompt`, `askUnsaved`, `resolveUnsaved`, org switch and pane close consult it, `dirtyEditorTabs()`)
- Modify: `app/Sources/WakilApp/EditorPane.swift` (the inline prompt), the window's root view (the prompt for pane close / org switch / quit), `app/Sources/WakilApp/AppDelegate` (or wherever `applicationShouldTerminate` lives; add it if absent)
- Test: `app/Tests/WakilKitTests/WindowModelUnsavedTests.swift`

**Interfaces:**
- Produces:

```swift
public enum UnsavedIntent: Sendable, Equatable {
    case closeTab(pane: String, tab: Int)
    case closePane(pane: String)
    case switchOrganisation(String)
    case quit
}
public struct UnsavedPrompt: Sendable, Equatable { public var intent: UnsavedIntent; public var files: [String] }  // titles
public enum UnsavedChoice: Sendable { case save, dontSave, cancel }
// WindowModel:
public private(set) var unsavedPrompt: UnsavedPrompt?
public func resolveUnsaved(_ choice: UnsavedChoice) async
public func requestQuit() async -> Bool          // true: nothing unsaved, quit now
public private(set) var quitApproved: Int        // bumps when a quit prompt resolved to quit
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite @MainActor struct WindowModelUnsavedTests {
    @Test func closingADirtyTabAsksAndDontSaveDiscards() async throws {
        let (model, files) = await editorWindowWithFiles()
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        _ = await model.dispatch("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b")
        await model.closeFocusedTabOrPane()
        #expect(model.unsavedPrompt == UnsavedPrompt(intent: .closeTab(pane: pane, tab: 0), files: ["a.go"]))
        await model.resolveUnsaved(.dontSave)
        #expect(model.unsavedPrompt == nil && model.editor(pane)?.tabs.isEmpty == true)
        #expect(await files.disk["/p/api/a.go"]?.text == "a")
    }

    @Test func saveWritesThenCloses() async throws { /* as above; resolveUnsaved(.save) → disk "b", tab gone */ }

    @Test func cancelKeepsEverything() async throws { /* resolveUnsaved(.cancel) → tab still there, still dirty */ }

    @Test func closingAPaneWithDirtyTabsListsThemOnce() async throws {
        // two dirty tabs a.go, b.go; model.closePane(id: pane) (the ⌘W-on-empty / rail close path)
        // #expect(model.unsavedPrompt?.files == ["a.go", "b.go"]); pane still open
        // resolveUnsaved(.dontSave) → pane closed
    }

    @Test func aDirtyScratchTabIsNamedAndAnEmptyOneIsNot() async throws {
        // newScratch twice; type into the first only; close pane → files == ["Untitled-1"]
    }

    @Test func switchingOrganisationWithDirtyTabsAsksFirst() async throws {
        // a dirty tab; call the window's org switch entry point (read WindowModel for its name, e.g.
        // switchOrganisation(_:)); #expect(unsavedPrompt?.intent == .switchOrganisation("<org>"));
        // organisation unchanged until resolveUnsaved(.dontSave), then switched
    }

    @Test func quitWithNothingUnsavedQuitsAndWithDirtyTabsAsks() async throws {
        let (model, _) = await editorWindowWithFiles()
        await model.refreshContext()
        #expect(await model.requestQuit())
        await model.newScratch()
        let pane = try #require(model.layoutSnapshot.focusedId)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "x")
        #expect(await !model.requestQuit())
        #expect(model.unsavedPrompt?.intent == .quit)
        await model.resolveUnsaved(.dontSave)
        #expect(model.quitApproved == 1)
    }
}
```

Write the elided bodies in full, in the shape of the first test. `editorWindowWithFiles()` is
`editorWindow()` returning its `FakeFiles` too.

Run: `cd app && ../scripts/swift-test.sh --filter WindowModelUnsaved` — Expected: FAIL.

- [ ] **Step 2: Implement**

```swift
    public private(set) var unsavedPrompt: UnsavedPrompt?
    public private(set) var quitApproved = 0

    /// Every dirty tab, by pane, in canvas order — what closing everything would lose.
    private func dirtyEditorTabs(in only: String? = nil) -> [(pane: String, tab: Int, title: String)] {
        var out: [(String, Int, String)] = []
        for pane in layoutSnapshot.panes where pane.kind == "editor" && (only == nil || pane.id == only) {
            guard let s = editor(pane.id) else { continue }
            let titles = editorTabTitles(s.tabs)
            for (i, t) in s.tabs.enumerated() where t.dirty { out.append((pane.id, i, titles[i])) }
        }
        return out
    }

    private func askUnsaved(_ intent: UnsavedIntent, titles: [String]) {
        unsavedPrompt = UnsavedPrompt(intent: intent, files: titles)
    }

    /// Save / Don't Save / Cancel. Save writes every listed tab (a scratch tab asks for its path first
    /// and the intent waits); Don't Save drops them; then the intent runs. Cancel runs nothing.
    public func resolveUnsaved(_ choice: UnsavedChoice) async {
        guard let prompt = unsavedPrompt else { return }
        unsavedPrompt = nil
        if choice == .cancel { return }
        let scope: String? = {
            switch prompt.intent {
            case .closeTab(let pane, _), .closePane(let pane): pane
            case .switchOrganisation, .quit: nil
            }
        }()
        var targets = dirtyEditorTabs(in: scope)
        if case .closeTab(let pane, let tab) = prompt.intent { targets = targets.filter { $0.pane == pane && $0.tab == tab } }
        if choice == .save {
            for t in targets {
                guard let tab = editor(t.pane)?.tabs[safe: t.tab] else { continue }
                if tab.isScratch { editorSaveAsRequest = t.pane; return }   // the field takes over; nothing closes
                guard let path = tab.path,
                      await dispatch("editor_save", .object(["pane": .string(t.pane), "path": .string(path)])) != nil
                else { return }   // a failed save keeps everything (Rule 8: its error is in the tab)
            }
        }
        switch prompt.intent {
        case .closeTab(let pane, _):
            _ = await dispatch("editor_close", .object(["pane": .string(pane), "discard": .bool(true)]))
        case .closePane(let pane):
            _ = await dispatchLayout("pane_close", .object(["id": .string(pane)]))
        case .switchOrganisation(let org):
            await performOrganisationSwitch(org)   // the existing switch body, renamed — see below
        case .quit:
            quitApproved += 1
        }
        await refreshLayout()
        await refreshPanes()
    }

    public func requestQuit() async -> Bool {
        let dirty = dirtyEditorTabs()
        guard !dirty.isEmpty else { return true }
        askUnsaved(.quit, titles: dirty.map(\.title))
        return false
    }
```

Replace the Task 8 `askUnsaved(_:tabs:)` stub's call site with `askUnsaved(.closeTab(pane: pane, tab: i), titles: [editorTabTitles(s.tabs)[i]])`.

`closePane(id:)`: before dispatching, `let dirty = dirtyEditorTabs(in: id); if !dirty.isEmpty { askUnsaved(.closePane(pane: id), titles: dirty.map(\.title)); return false }`.

Org switch: find the window's public org-switch entry point (search `func switchOrganisation` /
`func switchOrg` in `WindowModel.swift`). Rename its body to `private func performOrganisationSwitch(_:)`;
the public method becomes: `let dirty = dirtyEditorTabs(); if !dirty.isEmpty { askUnsaved(.switchOrganisation(org), titles: dirty.map(\.title)); return }`
then `await performOrganisationSwitch(org)`. Keep its return type; existing org-switch tests must pass
unchanged (they have no editor panes).

`[safe:]` — add `extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }`
privately in this file if none exists.

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelUnsaved|WindowModelEditor|OrgSwitch'` — Expected: PASS.

- [ ] **Step 3: Draw the prompt and hook quit**

- `EditorPane`: when `unsavedPrompt?.intent == .closeTab(pane: thisPane, _)`, an inline bar over the
  tab strip: *"Save changes to `a.go`?"* — **Save** / **Don't Save** / **Cancel** (`editor.unsaved.*`
  identifiers), Esc = Cancel, Return = Save.
- The window's root view (where the org plane and confirmation overlays are drawn — find
  `model.pending` in `WakilApp`): for `.closePane`, `.switchOrganisation`, `.quit`, the same bar centred
  on the canvas, listing the files (*"Unsaved changes in a.go, Untitled-1"*), same three buttons and
  identifiers.
- Quit: in the app delegate, `applicationShouldTerminate(_:)` returns `.terminateNow` when
  `await model.requestQuit()` is true; otherwise `.terminateLater`, and an `.onChange(of: model.quitApproved)`
  in the root view calls `NSApp.reply(toApplicationShouldTerminate: true)`; a Cancel calls
  `NSApp.reply(toApplicationShouldTerminate: false)` (add `public private(set) var quitCancelled: Int`
  bumped by `resolveUnsaved(.cancel)` when the intent was `.quit`, with a test line in
  `quitWithNothingUnsavedQuitsAndWithDirtyTabsAsks`). If the delegate cannot await, start a `Task`
  and return `.terminateLater` unconditionally, replying from the task.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp app/Tests/WakilKitTests/WindowModelUnsavedTests.swift
git commit -m "Unsaved edits ask before a tab, a pane, an org switch or quit drops them (3b-i PR 9)"
```

---

### Task 10: Charter, docs and the acceptance doc (PR 10)

**Files:**
- Modify: `docs/wakil/decisions.md` (Decision 36), `docs/wakil/north-star.md` (Invariant 6 table row and "Still refused"; Decision table row 36), `docs/wakil/design-language.md` §11, `docs/wakil/open-questions.md` (Q4), `docs/architecture/wakilkit.md` (Editor/ as built), `docs/architecture/flows.md` or `state.md` if they list pane kinds, `CONTRIBUTING.md` (Git → "Git and Editor are examples")
- Create: `docs/wakil/phase-3b-i-acceptance.md`

- [ ] **Step 1: Decision 36** — append to `decisions.md` after Decision 35, in its style:

```markdown
36. **The editor is the project's one code surface: file write earns its way in, and the Git pane
    folds into it.**
    *(2026-10-11, operator, during the 3b-i design.)*
    **File write** — local files inside the active project's roots — is the next write to earn in
    under Invariant 6. Its price is *allow* in production and outside it, for the operator and the
    agent alike, voice included: the agent's harness already has a bare file-write tool, so an editor
    write adds no reach — the argument that settled the terminal. Gating it would add friction and no
    safety. **Still refused:** any path outside the roots (after resolving symlinks), file delete,
    rename and move; each would earn in on its own. Mechanism: `wakil-files` (`files_write`), confined
    by `wakilcore.ConfineFilePath`; `editor_save` declares the price.
    **The Git pane folds into the editor** (sub-phase 3b-iii): the editor's left column has *Files* and
    *Changes*; a changed file's diff opens as an editor tab. This revises Decision 17's *"Git is a
    separate dual-driven pane"*: git stays project-level across roots, and so does the editor (its tree
    is the project's roots), so the split had nothing left to separate.
    *Reverse if:* a write the agent made through the editor is found to reach something its own file
    tools could not — then the price becomes *gate* for the agent.
```

- [ ] **Step 2: Charter** (`north-star.md`, at 3998/4000 words — count with `wc -w` before and after)

- Invariant 6 table: add `| File write — local files inside the project's roots | wakil-files | 2026-10-11 |`.
- "Still refused": append *", file delete and rename"* after the terminal clause's end — or, if over the
  word budget, cut the same number of words from the same paragraph and say which in the commit.
- Decisions table: add row `| 36 | File write earns in (allow everywhere, inside the roots); the Git pane folds into the editor | an editor write reaches what the agent's own tools cannot |`.
- Decision 17's table row: no change (Decision 36 records the revision).

Run: `wc -w docs/wakil/north-star.md` — Expected: ≤ the budget the file states.

- [ ] **Step 3: design-language §11** — the Editor row's notes become:
*"Native, Monaco-based — see below. The one partial exception to dual-drive. ⌘T opens a scratch tab;
files open from ⌘P (Resources). Unsaved edits ask before anything drops them."*; the Git row gains, at
its end: *"Folds into the editor as its Changes view in 3b-iii (Decision 36)."*

- [ ] **Step 4: open-questions Q4** — strike it and add, in the table's style:
*"**CLOSED 2026-10-11 — yes, for six uses the operator named** (quick fix beside the agent, reviewing the
agent's changes, light writing, config and data files, scratch buffers sent to other panes, orienting and
reading logs). Heavy coding stays in VS Code (§5). Delivered in sub-phases 3b-i–3b-vii; 3b-i spec
`docs/superpowers/specs/2026-10-11-3b-i-editor-core-design.md`."*

- [ ] **Step 5: Architecture docs** — update `docs/architecture/wakilkit.md`'s `### Editor/` to what was
built (add `editor_focus_tab`, `editor_refresh`, `editor_restore`, the restore step), the "Pane kinds"
section's list of kinds, and `### App/` (editor watcher, unsaved prompt). Search the other
`docs/architecture/*.md` for "git pane" lists of kinds and add the editor where a list of kinds appears.

Run: `make docs-check` — Expected: PASS.

- [ ] **Step 6: The acceptance doc** — `docs/wakil/phase-3b-i-acceptance.md`, in the shape of
`docs/wakil/phase-3a-i-acceptance.md` (read it), with a numbered walk table (≤ 10 rows):

| # | Do | Expect |
|---|---|---|
| 1 | ⌘P, type `confgo`, Return | `config.go` opens in a new editor pane, focused, highlighted as Go |
| 2 | Type a character, then ⌘S | The dirty dot appears, then clears; no dialog; `git diff` shows the change |
| 3 | Ask the agent "go to line 40 and select that line" | The cursor moves to 40 and the line is selected |
| 4 | Ask the agent to rename a variable on screen | The edit appears, the tab is dirty, ⌘Z undoes it |
| 5 | ⌘T, type `select 1`, *Set language…* → SQL, ⌘S, enter a path in a root, Return | The field arrives focused; the tab becomes that file |
| 6 | With a dirty tab, edit the same file in a terminal | *"changed on disk"* with Reload and Compare; Compare shows both; Reload takes the disk's text |
| 7 | Clean tab; edit the file in a terminal | The tab reloads in place; cursor and scroll stay |
| 8 | Dirty tab, ⌘W | *Save changes?* — Cancel keeps it; Don't Save closes it |
| 9 | Open three files, quit, relaunch | The three tabs are back, cursor and scroll where they were |
| 10 | Ask the agent to open `/etc/hosts` | Refused, naming Invariant 6 and Decision 36 |

- [ ] **Step 7: Commit**

```bash
git add docs CONTRIBUTING.md
git commit -m "Docs: Decision 36, Invariant 6's file write, §11, Q4 closed, Editor/ as built, 3b-i acceptance (3b-i PR 10)"
```

---

## Top of the stack, before merge (controller)

1. `make build && make test && make app-test` — full suites, controller only (Global Constraints).
2. The e2e auditor (Cover rung, `docs/agents/e2e.md`): checks for ⌘P file row, ⌘T, ⌘S, ⌘W, the dirty
   prompt, Reload, Compare, *Set language…*, the save-as field, and Rules 1, 3, 5, 7, 8; anything it
   cannot cover goes in `e2e/checks/uncoverable.tsv` with its reason.
3. A fresh whole-stack review (`superpowers:requesting-code-review`).
4. The operator walks `docs/wakil/phase-3b-i-acceptance.md` (Walk rung) — ask before any GUI run.
