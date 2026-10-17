# 3b-iv — File operations in the editor's tree — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create, rename/move and Move to Trash in the editor's Files tree, for the operator and the agent, with open tabs following.

**Architecture:** Three confined Go tools in `wakil-files` (`files_create`, `files_move`, `files_trash`) do every write; `files_list` gains the empty folders git cannot list. Three WakilKit actions (`editor_create`, `editor_rename`, `editor_trash`, price *allow*) call them and re-point or close tabs in every editor pane through pure functions; the Monaco renderer gains a re-key step so a renamed tab keeps its model and undo history. WakilApp adds the root **+**, context menus, an inline name field, F2 and ⌘⌫.

**Tech Stack:** Go 1.x (`CGO_ENABLED=0`), MCP Go SDK fork; Swift 6 / SwiftUI, Swift Testing; Monaco in a WKWebView.

**Spec:** `docs/superpowers/specs/2026-10-17-3b-iv-file-operations-design.md` (PR #17).

## Global Constraints

- Every path is confined to the active project's roots (Invariant 6, Decision 36); refusals name the invariant.
- A root itself is never moved or trashed.
- Nothing overwrites: create and move refuse an existing name (Rule 1's "destroys").
- Trash runs `/usr/bin/trash -s <path>`; when it is missing the error is exactly `Move to Trash needs macOS 15: /usr/bin/trash is missing`.
- Price `(production: .allow, otherwise: .allow)` on all three actions, `kind: .mutate`, `audience: .agentReachable`.
- Errors shown whole (Rule 8); the name field commits on focus loss (Rule 2), arrives focused (Rule 3), is disabled while its write runs (Rule 5).
- Never add `Co-Authored-By` or "Generated with Claude Code" lines to commits or PRs.
- Commit messages follow the repo's style: `3b-iv: <what>`.
- `make app-test` and `go test ./...` green at every task's end.

## Rulings taken while planning (amend the spec at Task 8)

- **R1 — Empty folders are listed.** git lists files, never folders, so a folder made by New Folder (or Finder) would not show in the tree. `files_list` gains `empty`: in a repository, the untracked folders `git ls-files --others --exclude-standard --directory` reports with no listed file under them; outside one, every folder the walk finds with no entries. The tree shows them as folder rows. Cost if wrong: one extra git call per listing.
- **R2 — A renamed tab is re-keyed, not reopened.** The renderer keys Monaco models by `file:<path>`, so a re-pointed tab would get a fresh model and lose its undo history, which the spec keeps. `EditorTab.formerKey` carries the old key once; `editorRenderSteps` emits `.rekey(from:to:)` before anything else, and the page moves its model. Cost if wrong: undo history lost on rename.
- **R3 — A move across volumes is refused** with `<from> and <to> are on different volumes; a move across volumes is not offered` (`os.Rename` answers `EXDEV`). Not a copy-then-delete.
- **R4 — Renaming to the same name is ignored**, answering success (Rule 7).

## Review Focus

1. **A dirty tab whose file is renamed while autosave is pending** — the autosave must write to the new path, never recreate the old one. Test in Task 6.
2. **A tab open on a file under a renamed folder in a pane of another conversation (hidden scope)** — it must re-point too (`editorPanesInEveryScope`). Test in Task 6.
3. **Case-only rename on APFS (`user.php` → `User.php`)** — `Lstat(to)` succeeds on the same file; must not be refused. Test in Task 1.
4. **A symlink inside a root pointing outside** — trash and rename act on the link; the target is untouched. Test in Task 1.
5. **Committing the name field by focus loss after Esc** — Esc cancels and the following blur must not create. Covered by the field's state machine in Task 7 and by the e2e auditor.

---

## File Structure

| File | Change |
|---|---|
| `internal/wakilcore/fileops.go` | **new** — `confineEntry`, `CreateEntry`, `MoveEntry`, `TrashEntry`, `trashBin` |
| `internal/wakilcore/fileops_test.go` | **new** |
| `internal/wakilcore/files.go` | `FileList.Empty`; `walked.empty`; `gitListEmpty`; walk records empty folders |
| `internal/wakilcore/files_test.go` | empty-folder listing tests |
| `cmd/wakil-files/main.go` | three tools; `files_write` description |
| `cmd/wakil-files/main_test.go` | served-and-confined tests |
| `app/Sources/WakilKit/Editor/EditorTree.swift` | `EditorRootListing.empty`; rows for empty folders |
| `app/Sources/WakilKit/Editor/EditorTabs.swift` | `editorRepointTabs`, `editorTabsAfterTrash`, `editorRenameTarget` |
| `app/Sources/WakilKit/Editor/EditorSnapshot.swift` | `EditorTab.formerKey` |
| `app/Sources/WakilKit/Editor/EditorRenderer.swift` | `.rekey` step, `rekeyModel` |
| `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `monaco-host.html` | `wakilRekey` |
| `app/Sources/WakilKit/Editor/EditorActions.swift` | three actions; `EditorActionError` cases |
| `app/Tests/WakilKitTests/EditorTestSupport.swift` | `FakeFiles` handles the three tools |
| `app/Tests/WakilKitTests/EditorFileOpsTests.swift` | **new** |
| `app/Sources/WakilApp/EditorColumn.swift` | **+**, context menus, name field, F2, ⌘⌫ |
| docs | Task 8 |

Stack (one unit of work per PR, `gh stack`): `-1-go` (Tasks 1–3), `-2-kit` (Tasks 4–6), `-3-app` (Task 7), `-4-docs` (Task 8).

---

### Task 1: Go — create, move, trash in wakilcore

**Files:**
- Create: `internal/wakilcore/fileops.go`, `internal/wakilcore/fileops_test.go`

**Interfaces:**
- Produces: `CreateEntry(path, kind string, roots []string) (FileEntry, error)`, `MoveEntry(from, to string, roots []string) (FileMoved, error)`, `TrashEntry(ctx context.Context, path string, roots []string) (FileEntry, error)`; `type FileEntry struct{Path, Root, Kind string}` (json `path`,`root`,`kind`); `type FileMoved struct{From, To, Kind string}` (json `from`,`to`,`kind`); package var `trashBin = "/usr/bin/trash"`.

- [ ] **Step 1: Write the failing tests** — `internal/wakilcore/fileops_test.go`, using `filesRoots` and `write` from `files_test.go`:

```go
package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateEntryMakesAFileAndItsParents(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "x", "y", "n.go")
	e, err := CreateEntry(p, "file", []string{a})
	if err != nil || e.Kind != "file" || e.Root != a {
		t.Fatalf("got %+v %v", e, err)
	}
	if got, _ := os.ReadFile(p); len(got) != 0 {
		t.Fatalf("not empty: %q", got)
	}
}

func TestCreateEntryMakesAFolder(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "d")
	if _, err := CreateEntry(p, "dir", []string{a}); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(p); err != nil || !fi.IsDir() {
		t.Fatalf("no folder: %v", err)
	}
}

func TestCreateEntryRefusesAnExistingName(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "keep")
	if _, err := CreateEntry(p, "file", []string{a}); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("err %v", err)
	}
	if got, _ := os.ReadFile(p); string(got) != "keep" {
		t.Fatal("overwrote")
	}
}

func TestCreateEntryRefusesOutsideTheRootsAndThroughALink(t *testing.T) {
	a, _, outside := filesRoots(t)
	if _, err := CreateEntry(filepath.Join(outside, "f"), "file", []string{a}); err == nil {
		t.Fatal("created outside")
	}
	if err := os.Symlink(outside, filepath.Join(a, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateEntry(filepath.Join(a, "escape", "f"), "file", []string{a}); err == nil {
		t.Fatal("created through a link")
	}
	if _, err := os.Stat(filepath.Join(outside, "f")); err == nil {
		t.Fatal("a file landed outside")
	}
}

func TestCreateEntryRefusesDotNamesAndABadKind(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, p := range []string{a + "/..", a + "/."} {
		if _, err := CreateEntry(p, "dir", []string{a}); err == nil {
			t.Fatalf("made %s", p)
		}
	}
	if _, err := CreateEntry(filepath.Join(a, "k"), "link", []string{a}); err == nil {
		t.Fatal("kind link accepted")
	}
}

func TestMoveEntryRenamesAndCreatesParents(t *testing.T) {
	a, _, _ := filesRoots(t)
	from := filepath.Join(a, "a.go")
	write(t, from, "x")
	to := filepath.Join(a, "sub", "b.go")
	m, err := MoveEntry(from, to, []string{a})
	if err != nil || m.Kind != "file" {
		t.Fatalf("got %+v %v", m, err)
	}
	if got, _ := os.ReadFile(to); string(got) != "x" {
		t.Fatal("not moved")
	}
}

func TestMoveEntryAcrossRootsAndAFolder(t *testing.T) {
	a, b, _ := filesRoots(t)
	write(t, filepath.Join(a, "d", "f.txt"), "x")
	if _, err := MoveEntry(filepath.Join(a, "d"), filepath.Join(b, "d2"), []string{a, b}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(b, "d2", "f.txt")); string(got) != "x" {
		t.Fatal("folder not moved")
	}
}

func TestMoveEntryCaseOnlyRenameWorks(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "user.php"), "x")
	if _, err := MoveEntry(filepath.Join(a, "user.php"), filepath.Join(a, "User.php"), []string{a}); err != nil {
		t.Fatal(err)
	}
	names, _ := os.ReadDir(a)
	if len(names) != 1 || names[0].Name() != "User.php" {
		t.Fatalf("names %v", names)
	}
}

func TestMoveEntrySameNameIsIgnored(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "x")
	if _, err := MoveEntry(p, p, []string{a}); err != nil {
		t.Fatal(err)
	}
}

func TestMoveEntryRefusesAnExistingTargetIntoItselfARootAndOutside(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(a, "f"), "1")
	write(t, filepath.Join(a, "g"), "2")
	write(t, filepath.Join(a, "d", "x"), "3")
	cases := [][2]string{
		{filepath.Join(a, "f"), filepath.Join(a, "g")},
		{filepath.Join(a, "d"), filepath.Join(a, "d", "e", "d")},
		{a, filepath.Join(a, "r")},
		{filepath.Join(a, "f"), filepath.Join(outside, "f")},
		{filepath.Join(a, "nope"), filepath.Join(a, "n2")},
	}
	for _, c := range cases {
		if _, err := MoveEntry(c[0], c[1], []string{a}); err == nil {
			t.Fatalf("moved %s -> %s", c[0], c[1])
		}
	}
	if got, _ := os.ReadFile(filepath.Join(a, "g")); string(got) != "2" {
		t.Fatal("overwrote g")
	}
}

func TestMoveEntryMovesALinkAsItself(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "t"), "out")
	if err := os.Symlink(filepath.Join(outside, "t"), filepath.Join(a, "l")); err != nil {
		t.Fatal(err)
	}
	if _, err := MoveEntry(filepath.Join(a, "l"), filepath.Join(a, "l2"), []string{a}); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Lstat(filepath.Join(a, "l2")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("link not moved as a link")
	}
	if _, err := os.Stat(filepath.Join(outside, "t")); err != nil {
		t.Fatal("target touched")
	}
}

// fakeTrash points trashBin at a script that records its arguments and removes the path.
func fakeTrash(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "trash")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"" + bin + ".args\"\nrm -rf \"$2\"\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := trashBin
	trashBin = bin
	t.Cleanup(func() { trashBin = old })
	return bin + ".args"
}

func TestTrashEntryRunsTheTrashOnTheConfinedPath(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "x")
	args := fakeTrash(t)
	if _, err := TrashEntry(context.Background(), p, []string{a}); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(args)
	if string(got) != "-s\n"+p+"\n" {
		t.Fatalf("args %q", got)
	}
}

func TestTrashEntryTrashesALinkNotItsTarget(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "t"), "out")
	l := filepath.Join(a, "l")
	if err := os.Symlink(filepath.Join(outside, "t"), l); err != nil {
		t.Fatal(err)
	}
	args := fakeTrash(t)
	if _, err := TrashEntry(context.Background(), l, []string{a}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(args); string(got) != "-s\n"+l+"\n" {
		t.Fatalf("args %q", got)
	}
}

func TestTrashEntryRefusesARootOutsideAndAMissingPath(t *testing.T) {
	a, _, outside := filesRoots(t)
	fakeTrash(t)
	write(t, filepath.Join(outside, "f"), "x")
	for _, p := range []string{a, filepath.Join(outside, "f"), filepath.Join(a, "nope")} {
		if _, err := TrashEntry(context.Background(), p, []string{a}); err == nil {
			t.Fatalf("trashed %s", p)
		}
	}
}

func TestTrashEntryWithoutTheBinarySaysMacOS15(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "x")
	old := trashBin
	trashBin = filepath.Join(t.TempDir(), "missing")
	t.Cleanup(func() { trashBin = old })
	_, err := TrashEntry(context.Background(), p, []string{a})
	if err == nil || err.Error() != "Move to Trash needs macOS 15: "+trashBin+" is missing" {
		t.Fatalf("err %v", err)
	}
}
```

Note: the exact missing-binary text uses the variable so the test is independent of the path; in production it reads `Move to Trash needs macOS 15: /usr/bin/trash is missing`. If `UserError(...).Error()` adds a prefix in this package, compare with `strings.Contains` on the same text instead.

- [ ] **Step 2: Run to verify they fail**

Run: `CGO_ENABLED=0 go test ./internal/wakilcore -run 'Entry' -count=1`
Expected: FAIL — `undefined: CreateEntry` (and the others).

- [ ] **Step 3: Implement** — `internal/wakilcore/fileops.go`:

```go
package wakilcore

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// trashBin moves a path to the user's Trash. macOS ships it from 15; Go is built without cgo, so
// NSFileManager is out of reach (3b-iv, Decision 41). A variable so tests point it at a fake.
var trashBin = "/usr/bin/trash"

// FileEntry is a file or folder a 3b-iv write made or trashed.
type FileEntry struct {
	Path string `json:"path"`
	Root string `json:"root"`
	Kind string `json:"kind"` // "file" or "dir"
}

// FileMoved is a rename or move.
type FileMoved struct {
	From string `json:"from"`
	To   string `json:"to"`
	Kind string `json:"kind"`
}

func entryKind(fi fs.FileInfo) string {
	if fi.IsDir() {
		return "dir"
	}
	return "file"
}

// confineEntry confines path's parent folder and keeps its last name unresolved, so a link is
// created, moved or trashed as itself and nothing outside the roots is touched (3b-iv). A root
// itself, and "." or ".." as the name, are refused.
func confineEntry(path string, roots []string, mustExist bool) (string, string, error) {
	if !filepath.IsAbs(path) {
		return "", "", UserError("path must be absolute, got " + path)
	}
	if b := filepath.Base(path); b == "." || b == ".." {
		return "", "", UserError(path + " names no file or folder")
	}
	clean := filepath.Clean(path)
	name := filepath.Base(clean)
	if dir, e := filepath.EvalSymlinks(filepath.Dir(clean)); e == nil && slices.Contains(realRoots(roots), filepath.Join(dir, name)) {
		return "", "", UserError(path + " is a root of the active project; a root is not moved or trashed")
	}
	parent, root, err := ConfineFilePath(filepath.Dir(clean), roots, false)
	if err != nil {
		return "", "", err
	}
	real := filepath.Join(parent, name)
	if mustExist {
		if _, err := os.Lstat(real); err != nil {
			return "", "", UserError(path + " does not exist")
		}
	}
	return real, root, nil
}

func existsOr(path string, err error) error {
	if errors.Is(err, fs.ErrExist) {
		return UserError(path + " already exists")
	}
	return err
}

// CreateEntry makes an empty file (0644) or a folder, and any missing folders above it. It never
// overwrites: an existing name is refused.
func CreateEntry(path, kind string, roots []string) (FileEntry, error) {
	if kind != "file" && kind != "dir" {
		return FileEntry{}, UserError(`kind must be "file" or "dir", got ` + strconv.Quote(kind))
	}
	real, root, err := confineEntry(path, roots, false)
	if err != nil {
		return FileEntry{}, err
	}
	if _, err := os.Lstat(real); err == nil {
		return FileEntry{}, UserError(path + " already exists")
	}
	if err := os.MkdirAll(filepath.Dir(real), 0o755); err != nil {
		return FileEntry{}, err
	}
	if kind == "dir" {
		if err := os.Mkdir(real, 0o755); err != nil {
			return FileEntry{}, existsOr(path, err)
		}
	} else {
		f, err := os.OpenFile(real, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err != nil {
			return FileEntry{}, existsOr(path, err)
		}
		if err := f.Close(); err != nil {
			return FileEntry{}, err
		}
	}
	return FileEntry{Path: real, Root: root, Kind: kind}, nil
}

// MoveEntry renames or moves from to to, making missing folders above to. An existing to is
// refused unless it is from itself (a case-only rename on a case-insensitive volume); the same
// name is ignored (Rule 7); a move across volumes is refused (ruling R3).
func MoveEntry(from, to string, roots []string) (FileMoved, error) {
	src, _, err := confineEntry(from, roots, true)
	if err != nil {
		return FileMoved{}, err
	}
	dst, _, err := confineEntry(to, roots, false)
	if err != nil {
		return FileMoved{}, err
	}
	si, err := os.Lstat(src)
	if err != nil {
		return FileMoved{}, err
	}
	moved := FileMoved{From: src, To: dst, Kind: entryKind(si)}
	if dst == src {
		return moved, nil
	}
	if strings.HasPrefix(dst, src+string(filepath.Separator)) {
		return FileMoved{}, UserError("cannot move " + from + " into itself (" + to + ")")
	}
	if di, err := os.Lstat(dst); err == nil && !os.SameFile(si, di) {
		return FileMoved{}, UserError(to + " already exists")
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return FileMoved{}, err
	}
	if err := os.Rename(src, dst); err != nil {
		if errors.Is(err, syscall.EXDEV) {
			return FileMoved{}, UserError(from + " and " + to + " are on different volumes; a move across volumes is not offered")
		}
		return FileMoved{}, err
	}
	return moved, nil
}

// TrashEntry moves path to the user's Trash through trashBin; a link goes as itself.
func TrashEntry(ctx context.Context, path string, roots []string) (FileEntry, error) {
	real, root, err := confineEntry(path, roots, true)
	if err != nil {
		return FileEntry{}, err
	}
	if _, err := os.Stat(trashBin); err != nil {
		return FileEntry{}, UserError("Move to Trash needs macOS 15: " + trashBin + " is missing")
	}
	fi, err := os.Lstat(real)
	if err != nil {
		return FileEntry{}, err
	}
	if out, err := exec.CommandContext(ctx, trashBin, "-s", real).CombinedOutput(); err != nil {
		return FileEntry{}, UserError("could not move " + path + " to the Trash: " + strings.TrimSpace(string(out)) + " (" + err.Error() + ")")
	}
	return FileEntry{Path: real, Root: root, Kind: entryKind(fi)}, nil
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `CGO_ENABLED=0 go test ./internal/wakilcore -run 'Entry' -count=1 -v`
Expected: PASS, every test. If the case-only test fails because the temp volume is case-sensitive, it still passes (`dst != src`, `Lstat(dst)` fails, rename proceeds) — no skip needed.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/fileops.go internal/wakilcore/fileops_test.go
git commit -m "3b-iv: create, move and Move to Trash in wakilcore, confined on the parent"
```

### Task 2: Go — `files_list` lists empty folders (ruling R1)

**Files:**
- Modify: `internal/wakilcore/files.go` (`FileList`, `walked`, `walkFiles`, `ListFiles`; add `gitListEmpty`)
- Test: `internal/wakilcore/files_test.go`

**Interfaces:**
- Produces: `FileList.Empty []string` (json `empty`, relative, slash-separated, sorted, never nil).

- [ ] **Step 1: Write the failing tests** (append to `files_test.go`; reuse the existing git-repo helper the listing tests use — find it with `grep -n "git\", \"init\"" internal/wakilcore/files_test.go` and call it the same way):

```go
func TestListFilesReportsEmptyFoldersOutsideARepository(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "full", "f.txt"), "x")
	if err := os.MkdirAll(filepath.Join(a, "hollow", "deeper"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(l.Empty, []string{"hollow/deeper"}) {
		t.Fatalf("empty %v", l.Empty)
	}
}

func TestListFilesReportsEmptyFoldersInARepository(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a) // the helper the repo listing tests already use
	write(t, filepath.Join(a, "f.txt"), "x")
	if err := os.MkdirAll(filepath.Join(a, "made"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(l.Empty, []string{"made"}) {
		t.Fatalf("empty %v", l.Empty)
	}
}
```

If the helper is named differently, use its name; do not add a second one. A folder holding only empty folders is reported as its leaves outside a repository and as itself inside one (git collapses it) — both are acceptable; the tests pin only the simple cases.

- [ ] **Step 2: Run to verify they fail**

Run: `CGO_ENABLED=0 go test ./internal/wakilcore -run 'EmptyFolders' -count=1`
Expected: FAIL — `l.Empty undefined`.

- [ ] **Step 3: Implement**

In `FileList` add, after `Repos`:

```go
	// Empty is the folders holding nothing git or the walk lists (3b-iv ruling R1): a folder New
	// Folder just made, which a file listing alone would never show.
	Empty []string `json:"empty"`
```

In `walked` add `empty []string` to the first field line (`files, ignored, heavy, repos, empty []string`).

Add below `gitListHeavy`:

```go
// gitListEmpty answers the repository's untracked folders that hold no file git lists: `--directory`
// reports such a folder as one "name/" entry; one holding a listed file is dropped by the caller.
func gitListEmpty(ctx context.Context, dir string) ([]string, error) {
	lines, err := gitLines(ctx, dir, "ls-files", "-z", "--others", "--exclude-standard", "--directory")
	if err != nil {
		return nil, err
	}
	var out []string
	for _, l := range lines {
		if strings.HasSuffix(l, "/") && !isNestedRepo(dir, l) {
			out = append(out, strings.TrimSuffix(l, "/"))
		}
	}
	return out, nil
}
```

In `ListFiles`'s git branch, after `w.addIgnoredOf(real, "", ignored)`:

```go
		if empty, eerr := gitListEmpty(ctx, real); eerr == nil {
			for _, d := range empty {
				if !slices.ContainsFunc(w.files, func(f string) bool { return strings.HasPrefix(f, d+"/") }) {
					w.empty = append(w.empty, d)
				}
			}
		}
```

In `walkFiles`, in the directory branch just before the final `return nil` of the closure (after the `.git` check), record an empty folder:

```go
		if entries, rerr := os.ReadDir(p); rerr == nil && len(entries) == 0 {
			w.empty = append(w.empty, rel)
		}
```

In `ListFiles`, add `&w.empty` to the sort-and-non-nil loop, and `Empty: w.empty` to the returned `FileList`.

- [ ] **Step 4: Run to verify they pass**

Run: `CGO_ENABLED=0 go test ./internal/wakilcore -count=1`
Expected: PASS, the whole package.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/files.go internal/wakilcore/files_test.go
git commit -m "3b-iv: files_list reports empty folders, which git never lists"
```

### Task 3: Go — serve `files_create`, `files_move`, `files_trash`

**Files:**
- Modify: `cmd/wakil-files/main.go`
- Test: `cmd/wakil-files/main_test.go`

**Interfaces:**
- Consumes: Task 1's three functions.
- Produces: MCP tools `files_create {path, kind}` → `FileEntry`; `files_move {from, to}` → `FileMoved`; `files_trash {path}` → `FileEntry`.

- [ ] **Step 1: Write the failing test** (append to `main_test.go`):

```go
func TestFilesCreateMoveAreServedAndConfined(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "n", "a.go")
	if res, out := callFiles(t, "files_create", map[string]any{"path": p, "kind": "file"}); res.IsError || out["kind"] != "file" {
		t.Fatalf("create %+v %v", res.Content, out)
	}
	q := filepath.Join(pdir, "n", "b.go")
	if res, out := callFiles(t, "files_move", map[string]any{"from": p, "to": q}); res.IsError || out["kind"] != "file" {
		t.Fatalf("move %+v %v", res.Content, out)
	}
	res, _ := callFiles(t, "files_move", map[string]any{"from": q, "to": "/tmp/escaped.go"})
	if !res.IsError || !strings.Contains(res.Content[0].(*mcp.TextContent).Text, "Invariant 6") {
		t.Fatalf("move outside not refused by the invariant: %+v", res.Content)
	}
	res, _ = callFiles(t, "files_trash", map[string]any{"path": pdir})
	if !res.IsError {
		t.Fatal("trashed the root")
	}
}
```

(Trash itself is not run through the server: it would move a real file to the developer's Trash. Task 1 covers it with the fake.)

- [ ] **Step 2: Run to verify it fails**

Run: `CGO_ENABLED=0 go test ./cmd/wakil-files -run CreateMove -count=1`
Expected: FAIL — the tool `files_create` is unknown.

- [ ] **Step 3: Implement** — in `main.go`, beside `writeArg`:

```go
type createArg struct {
	Path string `json:"path" jsonschema:"absolute path of the new file or folder, inside one of the active project's roots"`
	Kind string `json:"kind" jsonschema:"file or dir"`
}
type moveArg struct {
	From string `json:"from" jsonschema:"absolute path of the file or folder to move, inside the roots"`
	To   string `json:"to" jsonschema:"its new absolute path, inside the roots"`
}
type trashArg struct {
	Path string `json:"path" jsonschema:"absolute path of the file or folder to move to the Trash, inside the roots"`
}
```

In `newServer`, change `files_write`'s description to end `…Confined to the active project's roots (Invariant 6, Decision 36). Rename, move and delete are files_move and files_trash.` and add after it:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "files_create", Description: "Makes an empty file or a folder (kind file or dir), and missing folders above it. An existing name is refused, never overwritten. Confined to the active project's roots (Invariant 6, Decision 41)."},
		func(_ context.Context, _ *mcp.CallToolRequest, a createArg) (*mcp.CallToolResult, wakilcore.FileEntry, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileEntry{}, nil
			}
			e, err := wakilcore.CreateEntry(a.Path, a.Kind, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileEntry{}, nil
			}
			return nil, e, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "files_move", Description: "Renames or moves a file or folder (a link as itself), making missing folders above to. An existing to is refused; a case-only rename works; the same name is ignored; a root is never moved; a move across volumes is refused. Confined to the active project's roots (Invariant 6, Decision 41)."},
		func(_ context.Context, _ *mcp.CallToolRequest, a moveArg) (*mcp.CallToolResult, wakilcore.FileMoved, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileMoved{}, nil
			}
			m, err := wakilcore.MoveEntry(a.From, a.To, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileMoved{}, nil
			}
			return nil, m, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "files_trash", Description: "Moves a file or folder (a link as itself) to the user's Trash, where Finder's Put Back restores it; needs macOS 15's /usr/bin/trash. A root is never trashed. Confined to the active project's roots (Invariant 6, Decision 41)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a trashArg) (*mcp.CallToolResult, wakilcore.FileEntry, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileEntry{}, nil
			}
			e, err := wakilcore.TrashEntry(ctx, a.Path, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileEntry{}, nil
			}
			return nil, e, nil
		})
```

- [ ] **Step 4: Run to verify it passes**

Run: `CGO_ENABLED=0 go test ./... -count=1`
Expected: PASS. Then `make build` (the app bundles `bin/wakil-files`).

- [ ] **Step 5: Commit**

```bash
git add cmd/wakil-files/main.go cmd/wakil-files/main_test.go
git commit -m "3b-iv: wakil-files serves files_create, files_move and files_trash"
```

### Task 4: WakilKit — pure functions: re-point, after-trash, rename target, empty folder rows

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorTabs.swift`, `app/Sources/WakilKit/Editor/EditorTree.swift`, `app/Sources/WakilKit/Editor/EditorSnapshot.swift`
- Test: `app/Tests/WakilKitTests/EditorFileOpsTests.swift` (new), `app/Tests/WakilKitTests/EditorTreeTests.swift`

**Interfaces:**
- Produces:
  - `EditorTab.formerKey: String?` (init param `formerKey: String? = nil`, last).
  - `public func editorRepointTabs(_ tabs: [EditorTab], from: String, to: String, root: String) -> [EditorTab]` — a `.file` tab at `from` or under `from + "/"` gets `.file(path: to + suffix, root: root)`, `formerKey` = its old `editorTabKey`, `language` re-derived from the new path only when it was the old path's derived language; `.diff` tabs whose `root + "/" + path` is at or under `from` are removed.
  - `public func editorTabsAfterTrash(_ tabs: [EditorTab], path: String) -> [EditorTab]` — `.file` tabs at or under `path`: clean ones removed, dirty ones `diskState = .deleted`; `.diff` tabs at or under removed.
  - `public func editorActiveAfter(_ old: [EditorTab], active: Int?, new: [EditorTab]) -> Int?` — the active tab's subject (or former subject when re-pointed) kept if it survives; else `editorTabAfterClosing`'s neighbour rule against the old index.
  - `public func editorRenameTarget(of path: String, typed: String) -> String` — `typed` resolved against `path`'s folder and standardized (`sub/x.ts`, `../x.ts`); a leading `/` is taken relative to the folder too (never the disk root).
  - `EditorRootListing.empty: [String]` (from `content["empty"]`, default `[]`); `editorTreeRows` emits a `.folder` row for each empty folder, in tree order, closed, with no children.

- [ ] **Step 1: Write the failing tests** — `EditorFileOpsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func tab(_ path: String, text: String = "t", saved: String = "t") -> EditorTab {
    var t = EditorTab.file(path: path, root: "/p/api", text: saved, mtime: 1, language: editorLanguage(forPath: path))
    t.text = text
    return t
}

@Test func repointMovesAFileTabAndRemembersItsKey() {
    let out = editorRepointTabs([tab("/p/api/a.go")], from: "/p/api/a.go", to: "/p/api/b.go", root: "/p/api")
    #expect(out[0].path == "/p/api/b.go")
    #expect(out[0].formerKey == "file:/p/api/a.go")
}

@Test func repointMovesEveryTabUnderAFolderAndKeepsEdits() {
    let tabs = [tab("/p/api/d/x.go", text: "dirty"), tab("/p/api/dx.go"), tab("/p/api/d/e/y.go")]
    let out = editorRepointTabs(tabs, from: "/p/api/d", to: "/p/web/z", root: "/p/web")
    #expect(out.map(\.path) == ["/p/web/z/x.go", "/p/api/dx.go", "/p/web/z/e/y.go"])
    #expect(out[0].text == "dirty" && out[0].dirty)
    if case .file(_, let root) = out[0].subject { #expect(root == "/p/web") }
}

@Test func repointRelabelsTheLanguageOnlyWhenItWasDerived() {
    var manual = tab("/p/api/a.txt")
    manual.language = "sql"
    let out = editorRepointTabs([tab("/p/api/a.txt"), manual], from: "/p/api/a.txt", to: "/p/api/a.go", root: "/p/api")
    #expect(out[0].language == "go")
    // The second tab shares the path only in this test; a real pane never holds two.
    #expect(out[1].language == "sql")
}

@Test func repointDropsDiffTabsAtOrUnder() {
    let diff = EditorTab.diff(root: "/p/api", path: "d/x.go", group: .changed)
    let out = editorRepointTabs([diff, tab("/p/api/k.go")], from: "/p/api/d", to: "/p/api/e", root: "/p/api")
    #expect(out.map(\.path) == ["/p/api/k.go"])
}

@Test func trashClosesCleanTabsAndMarksDirtyOnesDeleted() {
    let tabs = [tab("/p/api/d/a.go"), tab("/p/api/d/b.go", text: "edit"), tab("/p/api/c.go")]
    let out = editorTabsAfterTrash(tabs, path: "/p/api/d")
    #expect(out.map(\.path) == ["/p/api/d/b.go", "/p/api/c.go"])
    #expect(out[0].diskState == .deleted && out[0].text == "edit")
}

@Test func activeFollowsItsTabOrFallsToANeighbour() {
    let old = [tab("/p/api/a.go"), tab("/p/api/b.go"), tab("/p/api/c.go")]
    let gone = editorTabsAfterTrash(old, path: "/p/api/b.go")
    #expect(editorActiveAfter(old, active: 1, new: gone) == 1)   // c.go, the neighbour
    #expect(editorActiveAfter(old, active: 2, new: gone) == 1)   // c.go itself
    let moved = editorRepointTabs(old, from: "/p/api/c.go", to: "/p/api/z.go", root: "/p/api")
    #expect(editorActiveAfter(old, active: 2, new: moved) == 2)
    #expect(editorActiveAfter(old, active: 0, new: []) == nil)
}

@Test func renameTargetResolvesAgainstTheItemsFolder() {
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "b.go") == "/p/api/d/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "sub/b.go") == "/p/api/d/sub/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "../b.go") == "/p/api/b.go")
    #expect(editorRenameTarget(of: "/p/api/d/a.go", typed: "/b.go") == "/p/api/d/b.go")
}
```

Append to `EditorTreeTests.swift`:

```swift
@Test func anEmptyFolderIsAFolderRow() {
    var l = EditorRootListing(root: "/p/api", files: ["a.go"], ignored: [], heavy: [], repos: [], truncated: false, error: nil)
    l.empty = ["made"]
    let rows = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    let made = rows.first { $0.id == "/p/api/made" }
    #expect(made?.kind == .folder && made?.open == false)
    #expect(rows.firstIndex { $0.id == "/p/api/made" }! < rows.firstIndex { $0.id == "/p/api/a.go" }!)   // folders first
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter 'EditorFileOpsTests|anEmptyFolderIsAFolderRow'`
Expected: FAIL — `cannot find 'editorRepointTabs' in scope`.

- [ ] **Step 3: Implement.**
  - `EditorSnapshot.swift`: add `public var formerKey: String?` with the doc comment `/// The key this tab was rendered under before a rename (3b-iv ruling R2): the renderer moves its model once.` and the init parameter `formerKey: String? = nil` after `peek`.
  - `EditorTabs.swift`:

```swift
/// `path` is `base` or under it.
private func editorAtOrUnder(_ path: String, _ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }

/// Tabs after `from` became `to` (3b-iv): file tabs at or under it follow, edits and all, keeping
/// their old key for the renderer (ruling R2); diff tabs at or under it close, Changes relists them.
public func editorRepointTabs(_ tabs: [EditorTab], from: String, to: String, root: String) -> [EditorTab] {
    tabs.compactMap { t in
        switch t.subject {
        case .file(let path, _) where editorAtOrUnder(path, from):
            var n = t
            let moved = to + path.dropFirst(from.count)
            n.formerKey = editorTabKey(t)
            n.subject = .file(path: moved, root: root)
            if t.language == editorLanguage(forPath: path) { n.language = editorLanguage(forPath: moved) }
            return n
        case .diff(let r, let p, _) where editorAtOrUnder(r + "/" + p, from):
            return nil
        default:
            return t
        }
    }
}

/// Tabs after `path` went to the Trash (3b-iv): clean file tabs close, dirty ones stay marked
/// deleted (a save recreates the file), diff tabs close.
public func editorTabsAfterTrash(_ tabs: [EditorTab], path: String) -> [EditorTab] {
    tabs.compactMap { t in
        switch t.subject {
        case .file(let p, _) where editorAtOrUnder(p, path):
            guard t.dirty else { return nil }
            var n = t
            n.diskState = .deleted
            return n
        case .diff(let r, let p, _) where editorAtOrUnder(r + "/" + p, path):
            return nil
        default:
            return t
        }
    }
}

/// The active index after `old` became `new`: the same tab if it survived (by subject, or by the
/// key it had before a rename), else the neighbour `editorTabAfterClosing` picks (Rule 6).
public func editorActiveAfter(_ old: [EditorTab], active: Int?, new: [EditorTab]) -> Int? {
    guard let a = active, a < old.count, !new.isEmpty else { return new.isEmpty ? nil : active.map { min($0, new.count - 1) } }
    let key = editorTabKey(old[a])
    if let i = new.firstIndex(where: { editorTabKey($0) == key || $0.formerKey == key }) { return i }
    // Survivors before the active one keep their order, so its neighbour sits at the same index.
    let before = old[..<a].filter { o in new.contains { editorTabKey($0) == editorTabKey(o) || $0.formerKey == editorTabKey(o) } }.count
    return min(before, new.count - 1)
}

/// Where a rename typed as `typed` lands: relative to `path`'s folder, standardized, so `sub/x`
/// moves down and `../x` up; a leading "/" is still the folder's (never the disk's root).
public func editorRenameTarget(of path: String, typed: String) -> String {
    let folder = (path as NSString).deletingLastPathComponent
    let rel = typed.drop { $0 == "/" }
    return ((folder as NSString).appendingPathComponent(String(rel)) as NSString).standardizingPath
}
```

  - `EditorTree.swift`: add `public var empty: [String]` to `EditorRootListing` (init param `empty: [String] = []` last; `init(root:content:)` reads `strings("empty")`; `failed` passes `[]`). In `editorTreeRows`, where the trie is built from `files` (and `ignored` when shown), insert each `empty` path as a folder node with no children, so it is emitted as a `.folder` row at its sorted place, folders first. Read the function's trie construction first and insert at the same point the folders of `files` are created; do not emit a disclosure state other than closed for it.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && swift test --filter 'EditorFileOpsTests|EditorTreeTests|EditorTabsTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor app/Tests/WakilKitTests/EditorFileOpsTests.swift app/Tests/WakilKitTests/EditorTreeTests.swift
git commit -m "3b-iv: tabs re-point and close by path; empty folders are tree rows"
```

### Task 5: Renderer — re-key a renamed tab's model (ruling R2)

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorRenderer.swift`, `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `app/Sources/WakilApp/monaco-host.html`
- Test: `app/Tests/WakilKitTests/EditorRendererTests.swift`

**Interfaces:**
- Consumes: `EditorTab.formerKey` (Task 4).
- Produces: `EditorRenderStep.rekey(from: String, to: String)`; `EditorRenderer.rekeyModel(from:to:)`; JS `window.wakilRekey(from, to)`.

- [ ] **Step 1: Write the failing tests** (append to `EditorRendererTests.swift`; build `rendered` the way its neighbours do):

```swift
@Test func aRenamedTabMovesItsModelInsteadOfShowingANewOne() {
    var t = EditorTab.file(path: "/p/api/b.go", root: "/p/api", text: "x", mtime: 1, language: "go")
    t.formerKey = "file:/p/api/a.go"
    let rendered = ["file:/p/api/a.go": EditorRendered(text: "x", language: "go", readOnly: false, agentSerial: 0,
                                                       cursor: t.cursor, selection: nil)]
    let snap = EditorSnapshot(tabs: [t], active: 0)
    let steps = editorRenderSteps(rendered: rendered, active: "file:/p/api/a.go", snapshot: snap)
    #expect(steps.first == .rekey(from: "file:/p/api/a.go", to: "file:/p/api/b.go"))
    #expect(!steps.contains(.dispose(key: "file:/p/api/a.go")))
    #expect(!steps.contains { if case .show = $0 { true } else { false } })
    let after = editorRenderedAfter(steps, rendered: rendered, snapshot: snap)
    #expect(after["file:/p/api/a.go"] == nil && after["file:/p/api/b.go"] != nil)
}

@Test func aFormerKeyAlreadyMovedIsNotMovedAgain() {
    var t = EditorTab.file(path: "/p/api/b.go", root: "/p/api", text: "x", mtime: 1, language: "go")
    t.formerKey = "file:/p/api/a.go"
    let rendered = ["file:/p/api/b.go": EditorRendered(text: "x", language: "go", readOnly: false, agentSerial: 0,
                                                       cursor: t.cursor, selection: nil)]
    let steps = editorRenderSteps(rendered: rendered, active: "file:/p/api/b.go", snapshot: EditorSnapshot(tabs: [t], active: 0))
    #expect(!steps.contains { if case .rekey = $0 { true } else { false } })
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter EditorRendererTests`
Expected: FAIL — `type 'EditorRenderStep' has no member 'rekey'`.

- [ ] **Step 3: Implement.**
  - Add `case rekey(from: String, to: String)` to `EditorRenderStep`, and `func rekeyModel(from: String, to: String)` to the `EditorRenderer` protocol (doc: `/// Move from's model, undo history and marks to to (a renamed tab, 3b-iv R2).`).
  - At the top of `editorRenderSteps`, before any other step: make `var rendered = rendered` and `var active = active`; for each tab with `formerKey = f`, `key = editorTabKey(tab)`, where `rendered[key] == nil` and `rendered[f] != nil`: append `.rekey(from: f, to: key)`, move `rendered[key] = rendered[f]; rendered[f] = nil`, and `if active == f { active = key }`. The rest of the function then runs against the moved dictionary, so no `.show` or `.dispose` follows for either key.
  - In `editorRenderedAfter`, before the dispose loop: `for case .rekey(let f, let k) in steps { out[k] = out[f]; out[f] = nil }`.
  - In `editorApply`: `case .rekey(let f, let k): renderer.rekeyModel(from: f, to: k)`.
  - Every other `EditorRenderer` conformer (grep `: EditorRenderer` / `EditorRenderer {` in `app/`, including the test double in `EditorRendererTests.swift`) gains `rekeyModel`; the test double records it as its other calls are recorded.
  - `MonacoEditorRenderer.swift`: `func rekeyModel(from: String, to: String) { run("wakilRekey(\(Self.js(from)),\(Self.js(to)))") }`.
  - `monaco-host.html`, beside `wakilDispose`: move every per-key map. First list them: `grep -n "\[key\]" app/Sources/WakilApp/monaco-host.html` — at least `models`, `basis`, `marks`; include any view-state or peek map found keyed the same way.

```js
    // A renamed tab (3b-iv R2): its model, undo history and marks move to the new key.
    window.wakilRekey = function (from, to) {
      [models, basis, marks].forEach(function (m) { if (from in m) { m[to] = m[from]; delete m[from]; } });
      if (current === from) current = to;
    };
```

  - The view keeps `rendered` in state and recomputes it with `editorRenderedAfter`; nothing else changes there.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && swift test --filter EditorRendererTests && make app`
Expected: PASS, and the app builds.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorRenderer.swift app/Sources/WakilApp/MonacoEditorRenderer.swift app/Sources/WakilApp/monaco-host.html app/Tests/WakilKitTests/EditorRendererTests.swift
git commit -m "3b-iv: a renamed tab's Monaco model moves to its new key, undo history kept"
```

### Task 6: WakilKit — `editor_create`, `editor_rename`, `editor_trash`

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift`, `app/Tests/WakilKitTests/EditorTestSupport.swift`
- Test: `app/Tests/WakilKitTests/EditorFileOpsTests.swift`

**Interfaces:**
- Consumes: Task 3's tools; Task 4's `editorRepointTabs`, `editorTabsAfterTrash`, `editorActiveAfter`; existing `confine`, `requireFiles`, `filesTool`, `editorPane`, `openFile`, `persist`, `reply`, `panes.editorPanesInEveryScope()`, `panes.updateEditor(in:paneId:_:)`, `fileLists?.invalidate(root:)`, `layout?.setEditorTabs`.
- Produces: actions
  - `editor_create {path, kind: "file"|"dir", pane?}` — a file opens pinned (`openFile(..., preview: false)`) and is the active tab; a folder is opened in the column (`updateColumn` adds its parent chain to `open`) and the reply carries `"made": path`.
  - `editor_rename {path, to, pane?}` — reply carries `"from"`, `"to"`.
  - `editor_trash {path, pane?}` — reply carries `"trashed": path`.

- [ ] **Step 1: Teach `FakeFiles` the three tools.** In `perform`, beside `files_write`:

```swift
        case "files_create":
            let kind = optionalString(arguments, "kind") ?? "file"
            if disk[path] != nil || madeDirs.contains(path) {
                return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("\(path) already exists")])])])
            }
            if kind == "dir" { madeDirs.insert(path) } else { put(path, "") }
            return ok(["path": .string(path), "root": .string(""), "kind": .string(kind)])
        case "files_move":
            let from = optionalString(arguments, "from") ?? "", to = optionalString(arguments, "to") ?? ""
            calls.append("files_move \(from) -> \(to)")
            if let moveError { return .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(moveError)])])]) }
            for (k, v) in disk where k == from || k.hasPrefix(from + "/") { disk[k] = nil; disk[to + k.dropFirst(from.count)] = v }
            return ok(["from": .string(from), "to": .string(to), "kind": .string(disk[to] == nil ? "dir" : "file")])
        case "files_trash":
            for k in disk.keys where k == path || k.hasPrefix(path + "/") { disk[k] = nil }
            return ok(["path": .string(path), "root": .string(""), "kind": .string("file")])
```

  Add `var madeDirs: Set<String> = []`, `var moveError: String?` and `func setMoveError(_ e: String?) { moveError = e }`. `files_move`'s `path` is empty, so the generic `calls.append` logs `files_move ` — the extra line above is the one tests read.

- [ ] **Step 2: Write the failing tests** (append to `EditorFileOpsTests.swift`):

```swift
@Test func renameRepointsTheTabInEveryPaneAndJournalsIt() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "v1", basis: 0)
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go"), "pane": .string(other)])
    try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/sub/b.go")])
    #expect(await f.files.calls.contains("files_move /p/api/a.go -> /p/api/sub/b.go"))
    let mine = await f.snapshot().tabs[0]
    #expect(mine.path == "/p/api/sub/b.go" && mine.text == "v1" && mine.dirty)
    #expect(await f.panes.editorSnapshot(paneId: other).tabs[0].path == "/p/api/sub/b.go")
}

@Test func aRefusedRenameLeavesTabsAndSaysWhy() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.files.setMoveError("/p/api/b.go already exists")
    await #expect(throws: (any Error).self) {
        try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/b.go")])
    }
    #expect(await f.snapshot().tabs[0].path == "/p/api/a.go")
}

@Test func renameOutsideTheRootsIsRefusedBeforeAnyCall() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    await #expect(throws: (any Error).self) {
        try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/etc/a.go")])
    }
    #expect(await !f.files.calls.contains { $0.hasPrefix("files_move") })
}

@Test func trashClosesACleanTabAndKeepsADirtyOne() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/d/a.go", "a")
    await f.files.put("/p/api/d/b.go", "b")
    try await f.dispatch("editor_open", ["path": .string("/p/api/d/a.go")])
    try await f.dispatch("editor_open", ["path": .string("/p/api/d/b.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 1, text: "b!", basis: 0)
    try await f.dispatch("editor_trash", ["path": .string("/p/api/d")])
    let tabs = await f.snapshot().tabs
    #expect(tabs.map(\.path) == ["/p/api/d/b.go"])
    #expect(tabs[0].diskState == .deleted && tabs[0].text == "b!")
    #expect(await f.snapshot().active == 0)
}

@Test func aDirtyTabLeftByTrashRecreatesItsFileOnSave() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "a!", basis: 0)
    try await f.dispatch("editor_trash", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_save")
    #expect(await f.files.text(of: "/p/api/a.go") == "a!")
}

@Test func createAFileOpensItPinned() async throws {
    let f = try await editorFixture()
    try await f.dispatch("editor_create", ["path": .string("/p/api/n/new.ts"), "kind": .string("file")])
    let s = await f.snapshot()
    #expect(s.tabs.map(\.path) == ["/p/api/n/new.ts"] && s.active == 0 && !s.tabs[0].preview)
}

@Test func createAnExistingNameIsRefusedWhole() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    do {
        try await f.dispatch("editor_create", ["path": .string("/p/api/a.go"), "kind": .string("file")])
        Issue.record("created over a file")
    } catch {
        #expect(String(describing: error).contains("/p/api/a.go already exists"))
    }
}

@Test func theThreeActionsAreAllowedInProductionForTheAgent() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "a")
    try await f.dispatch("editor_create", ["path": .string("/p/api/b.go"), "kind": .string("file")], origin: .agent, environment: "production")
    try await f.dispatch("editor_rename", ["path": .string("/p/api/b.go"), "to": .string("/p/api/c.go")], origin: .agent, environment: "production")
    try await f.dispatch("editor_trash", ["path": .string("/p/api/c.go")], origin: .agent, environment: "production")
}

// Review Focus 1. Autosave arms by path (EditorAutosave.observe); a renamed dirty tab must be armed
// under its new path, or its pending save would name a tab that no longer exists.
@Test func aRenamedDirtyTabIsArmedUnderItsNewPath() {
    var a = EditorAutosave()
    var clean = EditorTab.file(path: "/p/a", root: "/p", text: "x", mtime: 1, language: "go")
    _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [clean], active: 0), mode: .pause)
    clean.text = "y"; clean.edits = 1
    let typed = EditorSnapshot(tabs: [clean], active: 0)
    #expect(a.observe(pane: "e1", snapshot: typed, mode: .pause).arm == ["/p/a"])
    let moved = EditorSnapshot(tabs: editorRepointTabs(typed.tabs, from: "/p/a", to: "/p/b", root: "/p"), active: 0)
    #expect(a.observe(pane: "e1", snapshot: moved, mode: .pause).arm == ["/p/b"])
}

// Review Focus 2: a tab open in another conversation's pane (a scope not on screen) follows too.
@Test func aTabInAHiddenScopeIsRepointedToo() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "v0")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let home = await f.panes.activeScope
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    try await f.dispatch("editor_rename", ["path": .string("/p/api/a.go"), "to": .string("/p/api/b.go")])
    #expect(await f.panes.editorSnapshot(in: home, paneId: f.pane).tabs[0].path == "/p/api/b.go")
}
```

  If `aRenamedDirtyTabIsArmedUnderItsNewPath` fails, fix it in `EditorAutosave.observe`: a tab whose `formerKey` names a path it had armed is armed under its new path (and the old one dropped), and nothing else.

- [ ] **Step 3: Run to verify they fail**

Run: `cd app && swift test --filter EditorFileOpsTests`
Expected: FAIL — `unknown action editor_rename` (or the registry's equivalent).

- [ ] **Step 4: Implement** in `registerEditorActions`, after `editor_save`. One shared helper:

```swift
    /// Every editor pane in every scope gets `change` applied to its tabs, its active tab kept or
    /// moved to a neighbour (Rule 6), and its saved tabs written back (3b-iv: the tree is the
    /// project's, in every pane — Decision 37).
    @Sendable func retab(_ change: @escaping @Sendable ([EditorTab]) -> [EditorTab]) async {
        for target in await panes.editorPanesInEveryScope() {
            await panes.updateEditor(in: target.scope, paneId: target.paneId) { s in
                let new = change(s.tabs)
                guard new != s.tabs else { return }
                s.active = editorActiveAfter(s.tabs, active: s.active, new: new)
                s.tabs = new
            }
            if target.scope == await panes.activeScope { await persist(target.paneId) }
        }
    }
```

  (If `panes.activeScope` is not public, read how `editor_replace` persists the panes it touched and do the same.)

  Then:

```swift
    await registry.register(Action(
        name: "editor_create",
        description: "Make an empty file or a folder (kind file or dir) at path (absolute, inside a root), and "
            + "missing folders above it. A file opens as a pinned tab; a folder is opened in the tree. An "
            + "existing name is refused, never overwritten. Confined to the active project's roots (Invariant 6, "
            + "Decision 41). Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]),
                        "kind": .object(["type": .string("string"), "enum": .array([.string("file"), .string("dir")])])],
                       required: ["path", "kind"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_create")
            guard let raw = optionalString(params, "path") else { throw StandardActionError.missingParam(action: "editor_create", param: "path") }
            let kind = optionalString(params, "kind") ?? "file"
            let c = try await confine(raw, action: "editor_create")
            switch try await filesTool(try requireFiles("editor_create"), "files_create",
                                       ["path": .string(c.path), "kind": .string(kind)]) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok: break
            }
            _ = await fileLists?.invalidate(root: c.root)
            if kind == "file" {
                try await openFile(pane, path: c.path, at: nil, selection: nil, preview: false, action: "editor_create")
            } else {
                await updateColumn(pane) { col in
                    var p = (c.path as NSString).deletingLastPathComponent
                    while p.count >= c.root.count { if !col.open.contains(p) { col.open.append(p) }; p = (p as NSString).deletingLastPathComponent }
                }
            }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["made"] = .string(c.path)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_rename",
        description: "Rename or move a file or folder: path to to (both absolute, inside the roots; another root "
            + "is allowed). Open tabs on it, or under a moved folder, follow in every editor pane with their "
            + "unsaved edits; its diff tabs close. An existing to is refused; a root is never moved; a move "
            + "across volumes is refused. Confined to the active project's roots (Invariant 6, Decision 41). "
            + "Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "to": .object(["type": .string("string")])],
                       required: ["path", "to"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_rename")
            guard let rawFrom = optionalString(params, "path") else { throw StandardActionError.missingParam(action: "editor_rename", param: "path") }
            guard let rawTo = optionalString(params, "to") else { throw StandardActionError.missingParam(action: "editor_rename", param: "to") }
            let from = try await confine(rawFrom, action: "editor_rename")
            let to = try await confine(rawTo, action: "editor_rename")
            switch try await filesTool(try requireFiles("editor_rename"), "files_move",
                                       ["from": .string(from.path), "to": .string(to.path)]) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok: break
            }
            await retab { editorRepointTabs($0, from: from.path, to: to.path, root: to.root) }
            await updateColumn(pane, onlyIfChanged: true) { col in
                col.open = col.open.map { p in p == from.path || p.hasPrefix(from.path + "/") ? to.path + p.dropFirst(from.path.count) : p }
            }
            _ = await fileLists?.invalidate(root: from.root)
            if to.root != from.root { _ = await fileLists?.invalidate(root: to.root) }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["from"] = .string(from.path)
            o["to"] = .string(to.path)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_trash",
        description: "Move a file or folder at path (absolute, inside a root) to the Trash, where Finder's Put "
            + "Back restores it; no dialog (Rule 1). Its clean tabs close in every editor pane; a tab with "
            + "unsaved edits stays open, marked deleted, and saving it recreates the file. A root is never "
            + "trashed. Needs macOS 15. Confined to the active project's roots (Invariant 6, Decision 41). "
            + "Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])], required: ["path"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_trash")
            guard let raw = optionalString(params, "path") else { throw StandardActionError.missingParam(action: "editor_trash", param: "path") }
            let c = try await confine(raw, action: "editor_trash")
            switch try await filesTool(try requireFiles("editor_trash"), "files_trash", ["path": .string(c.path)]) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok: break
            }
            await retab { editorTabsAfterTrash($0, path: c.path) }
            _ = await fileLists?.invalidate(root: c.root)
            guard case .object(var o) = await reply(pane) else { return .null }
            o["trashed"] = .string(c.path)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))
```

  Check against the code as it is: the exact signatures of `schema(_:required:)`, `StandardActionError.missingParam`, `updateColumn`, `fileLists?.invalidate` (it answers a `Task`; awaiting `.value` is not needed for the reply, but tests that read the tree should await it — match `editor_save`'s neighbours). The autosave test from Step 2 decides whether `EditorAutosave` needs a change (see the note under it).

- [ ] **Step 5: Run to verify they pass**

Run: `cd app && swift test --filter 'EditorFileOpsTests|EditorActionsTests|EditorAutosaveTests'`, then `make app-test`.
Expected: PASS, the whole suite.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Editor app/Tests/WakilKitTests
git commit -m "3b-iv: editor_create, editor_rename and editor_trash, tabs following in every pane"
```

### Task 7: WakilApp — the **+**, context menus, the name field, F2 and ⌘⌫

**Files:**
- Modify: `app/Sources/WakilApp/EditorColumn.swift`

**Interfaces:**
- Consumes: the three actions (Task 6), `editorRenameTarget` (Task 4), `editorTreeSelection` (exists: next survivor, else previous).
- Produces: accessibility identifiers the e2e auditor will use — `editor.tree.add:<root>` (the **+**), `editor.tree.name` (the field), `editor.tree.name.error` (its error), menu items titled exactly `New File`, `New Folder`, `Rename`, `Move to Trash`.

No WakilApp test target exists; this task is verified by `make app` building, by the e2e auditor at Cover and by the operator at Walk. Keep logic in WakilKit's pure functions; the view only wires.

- [ ] **Step 1: State.** In `EditorColumn` add:

```swift
    /// The tree's inline name field (3b-iv): creating under a folder, or renaming a row.
    private enum NameEdit: Equatable { case create(folder: String, kind: String), rename(path: String) }
    @State private var nameEdit: NameEdit?
    @State private var nameText = ""
    @State private var nameError: String?
    @State private var nameBusy = false
    @FocusState private var nameFocused: Bool
```

- [ ] **Step 2: Commit and cancel**, one place each (Rule 2: focus loss commits; Rule 5: busy blocks a second commit; Rule 8: the error stays, the text kept; Esc clears `nameEdit` first so the blur that follows finds nothing to commit — Review Focus 5):

```swift
    private func commitName() {
        guard let edit = nameEdit, !nameBusy else { return }
        let typed = nameText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { cancelName(); return }
        nameBusy = true
        Task {
            defer { nameBusy = false }
            do {
                switch edit {
                case .create(let folder, let kind):
                    let path = editorRenameTarget(of: folder + "/_", typed: typed)
                    try await dispatchThrowing("editor_create", ["path": .string(path), "kind": .string(kind)])
                    if kind == "dir" { selected = path }
                case .rename(let path):
                    let to = editorRenameTarget(of: path, typed: typed)
                    try await dispatchThrowing("editor_rename", ["path": .string(path), "to": .string(to)])
                    selected = to
                }
                nameEdit = nil; nameError = nil
            } catch {
                nameError = String(describing: error)
                nameFocused = true
            }
        }
    }

    private func cancelName() { nameEdit = nil; nameError = nil; nameText = "" }
```

  `dispatch` in this view swallows errors; find how the view surfaces an action's error elsewhere (grep `catch` in `EditorColumn.swift` and `EditorPane.swift`) and add `dispatchThrowing` as a sibling of `dispatch` that rethrows instead, using the same underlying call. `editorRenameTarget(of: folder + "/_", typed:)` resolves against `folder` itself (the placeholder name is dropped).

- [ ] **Step 3: The field view.**

```swift
    private func nameField(depth: Int, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $nameText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text)
                .focused($nameFocused)
                .disabled(nameBusy)
                .onSubmit(commitName)
                .onKeyPress(.escape) { cancelName(); return .handled }
                .onChange(of: nameFocused) { _, now in if !now, nameEdit != nil { commitName() } }
                .onAppear { nameFocused = true }
                .accessibilityIdentifier("editor.tree.name")
            if let nameError {
                Text(nameError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("editor.tree.name.error")
            }
        }
        .padding(.leading, 6 + CGFloat(depth * 12)).padding(.trailing, 6).padding(.vertical, 2)
    }
```

  Rename preselects the stem (Rule 9): after the field appears, select the range up to the last `.` via the field editor — `DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: stemLength)) }` where `stemLength` is the UTF-16 length of the name before its last `.` (the whole name when there is none, or when the name starts with its only `.`).

- [ ] **Step 4: Place the field.** In `tree`'s `ForEach(rows)`: when `nameEdit == .rename(path: row.id)`, render `nameField(depth: row.depth, placeholder: row.name)` instead of `treeRow(row)`; after the row whose id is a `.create` edit's `folder`, render `nameField(depth: row.depth + 1, placeholder: kind == "dir" ? "folder name" : "file name")`. Starting a create opens the folder first (`dispatch("editor_tree_expand", ["path": folder])` when the row is closed) so the field sits among its children.

- [ ] **Step 5: Start edits** — one function each:

```swift
    private func startCreate(in folder: String, kind: String) {
        nameText = ""; nameError = nil
        nameEdit = .create(folder: folder, kind: kind)
        if let row = rows.first(where: { $0.id == folder }), !row.open {
            Task { await dispatch("editor_tree_expand", ["path": .string(folder)]) }
        }
    }
    private func startRename(_ row: EditorTreeRow) {
        guard row.kind == .file || row.kind == .folder || row.kind == .repo else { return }
        nameText = row.name; nameError = nil
        nameEdit = .rename(path: row.id)
    }
    private func trash(_ row: EditorTreeRow) {
        guard row.kind == .file || row.kind == .folder || row.kind == .repo else { return }
        let before = rows
        Task {
            await dispatch("editor_trash", ["path": .string(row.id)])
            selected = editorTreeSelection(after: row.id, previous: before, now: rows)
        }
    }
```

- [ ] **Step 6: The + and the menus.** In `rowLabel` for a `.root` row, trailing, shown when `hovered == row.id || selected == row.id` (add `@State private var hovered: String?` and `.onHover` on the row):

```swift
    Menu {
        Button("New File") { startCreate(in: row.id, kind: "file") }
        Button("New Folder") { startCreate(in: row.id, kind: "dir") }
    } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .accessibilityIdentifier("editor.tree.add:\(root)")
```

  On the row in `treeRow`, after `.onTapGesture`:

```swift
    .contextMenu {
        if row.kind != .file {
            Button("New File") { startCreate(in: row.id, kind: "file") }
            Button("New Folder") { startCreate(in: row.id, kind: "dir") }
        }
        if row.kind != .root {
            if row.kind != .file { Divider() }
            Button("Rename") { startRename(row) }
            Button("Move to Trash") { trash(row) }
        }
    }
```

  (`root` here is the hoisted `rootName(row)` local, as the identifier harvest requires — see the comment at the top of `treeRow`.)

- [ ] **Step 7: Keys.** In `treeKey`, before `guard !isChord(press)`:

```swift
        if press.key == .delete, press.modifiers == .command, let row = rows.first(where: { $0.id == selected }) {
            trash(row); return .handled
        }
```

  and in the `switch`, a case for F2 — SwiftUI has no `KeyEquivalent` for it, so match the character: `if press.characters == "\u{F705}"` (`NSF2FunctionKey`) before the `switch`, calling `startRename` on the selected row. While `nameEdit != nil`, `treeKey` returns `.ignored` for everything, so arrows and type-ahead do not move the selection under the field.

- [ ] **Step 8: Build and check by hand**

Run: `make app` then launch from the worktree (`make run` or the command the README gives) on a scratch project.
Expected: the **+** shows on hovering a root; New File puts a focused field in the root; typing `a/b.ts` and clicking away makes it and opens it; F2 on it, typing `c.ts` and Enter renames the tab; ⌘⌫ removes it and the selection lands on the next row; right-click on a folder shows the four items, on a file two, on a root two.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/WakilApp/EditorColumn.swift
git commit -m "3b-iv: the tree's + button, context menus, name field, F2 rename and ⌘⌫ to the Trash"
```

### Task 8: Docs and charter

**Files:**
- Modify: `docs/wakil/north-star.md`, `docs/wakil/decisions.md`, `docs/wakil/design-language.md`, `docs/superpowers/specs/2026-10-17-3b-iv-file-operations-design.md`

- [ ] **Step 1: North-star, Invariant 6** — net words must not grow (charter 4,026/4,000):
  - "Four have earned in." → "Five have earned in."
  - Table row: `| File create, move, Move to Trash — inside the roots | wakil-files | 2026-10-17 |`
  - Still-refused list: drop "— and file delete and rename" (keep the terminal clause, ending the sentence after "Invariant 4").
  - Count before and after: `wc -w docs/wakil/north-star.md`; the after count must be ≤ the before count. Trim the row's wording if not.

- [ ] **Step 2: `decisions.md`** — Decision 41 after Decision 40, from the spec's "Decisions the operator took" list (delete is Trash with no dialog; F2; the + and the menus; tabs follow; *allow* for both, voice included, Decision 36's argument; approach A with `/usr/bin/trash`), dated `*(2026-10-17, operator, during the 3b-iv design — docs/superpowers/specs/2026-10-17-3b-iv-file-operations-design.md.)*`, with *Reverse if:* "a trash or move the agent made through the editor reaches something its own `mv` or `rm` could not". In Decision 36, after "file delete, rename and move; each would earn in on its own." add " *(Earned in 2026-10-17, Decision 41.)*". In the appendix *Invariant 6 — the writes that have earned in*, add `### 2026-10-17 — file create, move and Move to Trash` with the justification: the Trash is undoable, so nothing is destroyed; the agent's harness already holds `mv`, `mkdir` and `rm`, so the editor adds no reach; all three are confined on the parent folder so a link is acted on as itself; and what stays refused (permanent delete, a root, anything outside the roots, a move across volumes).

- [ ] **Step 3: `design-language.md`** — in the editor tree section (grep "3b-iv" — it is named at line ~452), describe the root row's **+** (hover or selection, a menu of New File and New Folder) and the inline name field (monospaced 11pt, the row's indent, its error whole beneath it).

- [ ] **Step 4: Spec amendment** — append `## Amendment — 2026-10-17, while planning` to the spec with rulings R1–R4 from this plan, verbatim.

- [ ] **Step 5: Check and commit**

Run: `make docs-check` (expect only the pre-existing north-star word-count failure, at a count no higher than before).

```bash
git add docs
git commit -m "3b-iv: Decision 41, Invariant 6 earns file create, move and Move to Trash; spec amended"
```

---

## After the plan

Cover (the e2e auditor, `docs/agents/e2e.md`) writes the checks the spec's Testing section lists; Walk is the operator's, from a runbook `docs/wakil/phase-3b-iv-acceptance.md` the auditor renders. Neither is a task here.
