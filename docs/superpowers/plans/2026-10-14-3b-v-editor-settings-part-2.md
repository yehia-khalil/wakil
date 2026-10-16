# 3b-v Part 2: Show Ignored Files and Heavy Folders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator turns gitignored files off in the tree and ⌘P (app-wide), and edits each
project's heavy-folder list (per project), from the two Editor nodes part 1 added; a change
applies at once.

**Architecture:** Both settings join part 1's tiers in `internal/wakilcore/editorsettings.go`:
`showIgnored` in `~/.wakil/settings.json`, `heavyFolders` in `project.json`. Go's file listing
(`ListFiles`, `SearchFiles`) takes the heavy names as a parameter instead of the fixed
`HeavyDirs`, and `wakil-files` passes the active project's. Show-ignored is a view filter in
WakilKit: Go still lists ignored files; the tree builder and ⌘P's files source drop them when the
setting is off. A heavy-folder save re-lists every root, as a disk wake does.

**Tech Stack:** Go + `modelcontextprotocol/go-sdk` (wakil-ctx, wakil-files), Swift 6 / SwiftUI /
Swift Testing (WakilKit, WakilApp).

**Spec:** `docs/superpowers/specs/2026-10-13-3b-v-editor-settings-design.md` (part 2 rows of
*What the operator gets*, *Design*, *Errors and edges*, *Testing*). Part 1's plan
(`docs/superpowers/plans/2026-10-13-3b-v-editor-settings.md`) is merged (PR #402) and is the
pattern for everything here.

## Global Constraints

- **Show ignored files:** app-wide, `~/.wakil/settings.json` → `editor.showIgnored`, default
  **on** (3b-ii's behaviour). Off hides gitignored files from the tree and ⌘P. Search skips them
  either way. Heavy folders still show in the tree.
- **Heavy folders:** per project, `project.json` → `editor.heavyFolders`, default
  `["vendor", "node_modules"]`. `.git` is always heavy, never stored, shown as a fixed row.
  Matched by name at any depth, among the folders git ignores (3b-ii's meaning). An empty list
  is a value (only `.git` is heavy), distinct from absent (the default).
- **Heavy-folder validation** (each a `UserError` naming the folder): non-empty; no `/`; not `.`
  or `..`; not `.git`; no duplicates. Names are trimmed of surrounding whitespace first.
- **The non-git walk's skip list (`skippedDirs`) stays built in.** The setting governs heavy
  folders inside git repositories (and child repositories) only.
- Every write is read-modify-write from disk; a refused write writes nothing. Both writes stay
  `.control` + `.operatorOnly` (Decision 30); `ctx_editor_settings` stays `.read` +
  `.agentReachable`. **No new action** — the existing three gain fields.
- Decision 38 already names both settings ("(part 2)"); no new decision.
- No `Co-Authored-By` or "Generated with" lines in any commit (operator rule).
- Commit message style: `<Area>: <what> (3b-v part 2)`.
- Go tests: `go test ./internal/wakilcore/ -run <Name>`, `go test ./cmd/wakil-ctx/ -run <Name>`,
  `go test ./cmd/wakil-files/ -run <Name>`. Swift tests:
  `cd app && ../scripts/swift-test.sh --filter <Name>`. Run `make build` before a Swift run that
  depends on Go changes (`make app-test` does not build Go). **An implementer subagent runs only
  scoped filters; the controller runs `make test` and `make app-test`.**

## Review Focus

1. **Removing every heavy folder** — the list must persist as `[]` (only `.git` heavy), not snap
   back to `vendor, node_modules` on the next read. Pinned in Task 1
   (`TestAnEmptyHeavyFolderListIsKept`).
2. **A heavy-folder name holding glob characters** (`lib*`) — it must match only a folder with
   that exact name, not `library`. Pinned in Task 2 (`TestAHeavyFolderNameIsMatchedLiterally`).
3. **A hand-edited `heavyFolders` holding `.git`, `a/b`, `""` or a duplicate** — the bad entries
   are dropped on read and never reach git's pathspecs. Pinned in Task 1
   (`TestResolvedDropsBadHeavyFolders`).
4. **The selected tree row is an ignored file when show-ignored turns off** — the selection moves
   to a neighbour instead of pointing at a row that is gone. Pinned in Task 5
   (`hidingIgnoredFilesMovesTheSelectionOffAHiddenRow`).
5. **A heavy-folder write that is refused** (a duplicate) — nothing is re-listed; only a write
   that landed re-lists. Pinned in Task 5 (`aRefusedHeavyFolderWriteRelistsNothing`).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `internal/wakilcore/editorsettings.go` | modify | `ShowIgnored`, `HeavyFolders`: stored, resolved, validated, patched; `DefaultHeavyFolders`, `HeavyNames` |
| `internal/wakilcore/editorsettings_test.go` | modify | Their tests; slice-safe comparisons |
| `internal/wakilcore/configtree_test.go` | modify | Slice-safe comparisons, new fields |
| `internal/wakilcore/files.go` | modify | Heavy names as a parameter; `globLiteral`; `HeavyDirs` removed |
| `internal/wakilcore/files_test.go` | modify | `testHeavy` on every call; custom-list tests |
| `cmd/wakil-ctx/main.go`, `cmd/wakil-ctx/main_test.go` | modify | The two set tools' new fields; descriptions; round trip |
| `cmd/wakil-files/main.go`, `cmd/wakil-files/main_test.go` | modify | The active project's heavy names; descriptions; a served test |
| `app/Sources/WakilKit/Panes/SettingsTree.swift` | modify | `SettingsEditor.showIgnored`, `SettingsProjectEditor.heavyFolders` |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | modify | Forward `showIgnored` and `heavyFolders`; schemas |
| `app/Tests/WakilKitTests/EditorSettingsTests.swift` | modify | Decode and forward tests |
| `app/Sources/WakilKit/Editor/EditorTree.swift` | modify | `editorTreeRows(…, showIgnored:)` |
| `app/Sources/WakilKit/Command/PaletteSources.swift` | modify | `FilesSource(…, showIgnored:)` |
| `app/Sources/WakilKit/App/WindowModel.swift` | modify | ⌘P reads the setting; a heavy-folder save re-lists every root |
| `app/Tests/WakilKitTests/EditorTreeTests.swift`, `PaletteFilesSourceTests.swift`, `WindowModelEditorTests.swift` | modify | Their tests |
| `app/Sources/WakilApp/EditorSettingsForms.swift` | modify | Show-ignored row; `HeavyFoldersSettingRow` |
| `app/Sources/WakilApp/Canvas.swift`, `app/Sources/WakilApp/EditorPane.swift` | modify | Pass `showIgnored` to the tree |
| `docs/wakil/design-language.md`, `docs/architecture/go.md`, `docs/architecture/wakilkit.md` | modify | As built |

---

### Task 1: wakilcore — the two settings in both tiers

**Files:**
- Modify: `internal/wakilcore/editorsettings.go`
- Modify: `internal/wakilcore/editorsettings_test.go`
- Modify: `internal/wakilcore/configtree_test.go:339-347`
- Modify: `cmd/wakil-ctx/main_test.go:990-993` (one comparison, so the package still compiles)

**Interfaces:**
- Produces: `EditorAppSettings.ShowIgnored *bool`, `EditorAppValues.ShowIgnored bool`,
  `EditorProjectSettings.HeavyFolders *[]string`, `EditorProjectValues.HeavyFolders []string`,
  `EditorSettings.ShowIgnored bool`, `EditorSettings.HeavyFolders []string`,
  `EditorAppPatch.ShowIgnored *bool`, `EditorProjectPatch.HeavyFolders *[]string`,
  `var DefaultHeavyFolders = []string{"vendor", "node_modules"}`,
  `func HeavyNames(folders []string) []string` (`.git` first, then `folders`).
  JSON keys: `showIgnored`, `heavyFolders`.

`EditorProjectValues` and `EditorSettings` hold a slice from here on, so `==`/`!=` on them no
longer compiles. Every comparison of those two types becomes `reflect.DeepEqual`.

- [ ] **Step 1: Write the failing tests** — append to `internal/wakilcore/editorsettings_test.go`
  (add `"reflect"` to its imports):

```go
func strs(v ...string) *[]string { return &v }

// Spec: show ignored files defaults on (3b-ii's behaviour); the heavy folders default to
// vendor and node_modules.
func TestPartTwoDefaults(t *testing.T) {
	if !(EditorAppSettings{}).Resolved().ShowIgnored {
		t.Error("ShowIgnored defaults off; want on")
	}
	var p *EditorProjectSettings
	if got := p.Resolved().HeavyFolders; !reflect.DeepEqual(got, []string{"vendor", "node_modules"}) {
		t.Errorf("HeavyFolders = %v", got)
	}
}

func TestShowIgnoredIsWrittenAndRead(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{ShowIgnored: boolp(false)}); err != nil {
		t.Fatal(err)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if s.Editor.Resolved().ShowIgnored {
		t.Error("ShowIgnored stayed on after writing off")
	}
}

func TestHeavyFoldersAreWrittenTrimmedAndRead(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	if err := UpdateProjectEditorSettings(path, EditorProjectPatch{HeavyFolders: strs(" storage ", "dist")}); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := p.Editor.Resolved().HeavyFolders; !reflect.DeepEqual(got, []string{"storage", "dist"}) {
		t.Errorf("HeavyFolders = %v", got)
	}
}

// Review Focus 1: an empty list is a value — only .git is heavy — not "absent".
func TestAnEmptyHeavyFolderListIsKept(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	if err := UpdateProjectEditorSettings(path, EditorProjectPatch{HeavyFolders: strs()}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if !strings.Contains(string(b), `"heavyFolders": []`) {
		t.Errorf("project.json does not hold the empty list: %s", b)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := p.Editor.Resolved().HeavyFolders; got == nil || len(got) != 0 {
		t.Errorf("HeavyFolders = %#v; want an empty, non-nil list", got)
	}
}

func TestEachHeavyFolderRuleRefusesAndWritesNothing(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	before, _ := os.ReadFile(path)
	for _, bad := range [][]string{{""}, {"  "}, {"a/b"}, {"."}, {".."}, {".git"}, {"dist", "dist"}, {"dist", " dist"}} {
		err := UpdateProjectEditorSettings(path, EditorProjectPatch{HeavyFolders: &bad})
		if _, ok := IsUserError(err); err == nil || !ok {
			t.Errorf("%q: err = %v; want a UserError", bad, err)
		}
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Error("a refused write changed project.json")
	}
}

// Review Focus 3: a hand edit cannot put a bad name in front of git.
func TestResolvedDropsBadHeavyFolders(t *testing.T) {
	got := (&EditorProjectSettings{HeavyFolders: strs("dist", ".git", "a/b", "", "dist", " build ")}).Resolved().HeavyFolders
	if !reflect.DeepEqual(got, []string{"dist", "build"}) {
		t.Errorf("HeavyFolders = %v", got)
	}
}

func TestHeavyNamesPutsGitFirst(t *testing.T) {
	if got := HeavyNames([]string{"vendor"}); !reflect.DeepEqual(got, []string{".git", "vendor"}) {
		t.Errorf("HeavyNames = %v", got)
	}
	if got := HeavyNames(nil); !reflect.DeepEqual(got, []string{".git"}) {
		t.Errorf("HeavyNames(nil) = %v", got)
	}
}
```

Then make the existing comparisons slice-safe:

- `editorsettings_test.go:31` — `want` gains `ShowIgnored: true`.
- `editorsettings_test.go:45` — `p.Resolved() != (EditorProjectValues{TabSize: 4, InsertSpaces: true})`
  becomes `!reflect.DeepEqual(p.Resolved(), EditorProjectValues{TabSize: 4, InsertSpaces: true, HeavyFolders: []string{"vendor", "node_modules"}})`.
- `editorsettings_test.go:48` — the `v.TabSize != 4 || v.InsertSpaces` check is field-wise; leave it.
- `editorsettings_test.go:66` — the wanted `EditorAppValues` gains `ShowIgnored: true`.
- `editorsettings_test.go:156` — becomes `!reflect.DeepEqual(got, EditorProjectValues{TabSize: 2, InsertSpaces: false, HeavyFolders: []string{"vendor", "node_modules"}})`.
- `configtree_test.go:339` — the wanted `EditorAppValues` gains `ShowIgnored: true`.
- `configtree_test.go:345` — `tree.Projects[0].Editor != (EditorProjectValues{…})` becomes
  `!reflect.DeepEqual(tree.Projects[0].Editor, EditorProjectValues{TabSize: 2, InsertSpaces: false, HeavyFolders: []string{"vendor", "node_modules"}})`
  (add `"reflect"` to its imports if absent).
- `cmd/wakil-ctx/main_test.go:991-993` — `want` gains `ShowIgnored: true, HeavyFolders: []string{"vendor", "node_modules"}`
  and `got != want` becomes `!reflect.DeepEqual(got, want)` (add `"reflect"` to its imports).

Run `grep -rn "EditorProjectValues{\|EditorSettings{\|EditorAppValues{" --include='*_test.go' internal cmd`
afterwards: every hit must be one of the above.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'PartTwo|ShowIgnored|HeavyFolder|HeavyNames|EmptyHeavy'`
Expected: FAIL to compile — `unknown field ShowIgnored`, `undefined: HeavyNames`.

- [ ] **Step 3: Implement** in `internal/wakilcore/editorsettings.go`

Add `"slices"` and `"strings"` to the imports. Update the package comment's two tier lines:

```go
//   - App-wide, the operator's own, in ~/.wakil/settings.json under "editor": font size, word
//     wrap, autosave, showing ignored files. The file is design-language §14's "Wakil" scope,
//     and its first.
//   - Per project, the code's, in project.json under "editor": tab size, tabs or spaces, and the
//     heavy folders, so a teammate gets the same values.
```

Below the constants:

```go
// DefaultHeavyFolders are the heavy folders of a project that names none — 3b-ii's fixed list,
// less .git, which is always heavy and never stored.
var DefaultHeavyFolders = []string{"vendor", "node_modules"}

// HeavyNames is what the file listing treats as heavy: .git, then the project's folders.
func HeavyNames(folders []string) []string {
	return append([]string{".git"}, folders...)
}
```

The stored and resolved types become:

```go
type EditorAppSettings struct {
	FontSize    int    `json:"fontSize,omitempty"`
	WordWrap    bool   `json:"wordWrap,omitempty"`
	Autosave    string `json:"autosave,omitempty"`
	ShowIgnored *bool  `json:"showIgnored,omitempty"` // nil is the default, on
}

// EditorProjectSettings is the per-project tier as stored. InsertSpaces is a pointer because
// false (tabs) is a value and absent is the default (spaces); HeavyFolders likewise, because an
// empty list (only .git heavy) is a value and absent is DefaultHeavyFolders.
type EditorProjectSettings struct {
	TabSize      int       `json:"tabSize,omitempty"`
	InsertSpaces *bool     `json:"insertSpaces,omitempty"`
	HeavyFolders *[]string `json:"heavyFolders,omitempty"`
}

type EditorAppValues struct {
	FontSize    int    `json:"fontSize"`
	WordWrap    bool   `json:"wordWrap"`
	Autosave    string `json:"autosave"`
	ShowIgnored bool   `json:"showIgnored"`
}

type EditorProjectValues struct {
	TabSize      int      `json:"tabSize"`
	InsertSpaces bool     `json:"insertSpaces"`
	HeavyFolders []string `json:"heavyFolders"`
}

type EditorSettings struct {
	FontSize     int      `json:"fontSize"`
	WordWrap     bool     `json:"wordWrap"`
	Autosave     string   `json:"autosave"`
	ShowIgnored  bool     `json:"showIgnored"`
	TabSize      int      `json:"tabSize"`
	InsertSpaces bool     `json:"insertSpaces"`
	HeavyFolders []string `json:"heavyFolders"`
	AppError     string   `json:"appError,omitempty"`
}
```

Resolution:

```go
func (s EditorAppSettings) Resolved() EditorAppValues {
	v := EditorAppValues{FontSize: DefaultEditorFontSize, WordWrap: s.WordWrap, Autosave: AutosaveOff, ShowIgnored: true}
	if s.FontSize >= MinEditorFontSize && s.FontSize <= MaxEditorFontSize {
		v.FontSize = s.FontSize
	}
	if validAutosave(s.Autosave) {
		v.Autosave = s.Autosave
	}
	if s.ShowIgnored != nil {
		v.ShowIgnored = *s.ShowIgnored
	}
	return v
}

// Resolved fills the defaults; a nil receiver (a project with no editor block) is every default.
// A stored heavy folder that breaks a rule — only a hand edit can put one there — is dropped, so
// no bad name reaches git's pathspecs.
func (s *EditorProjectSettings) Resolved() EditorProjectValues {
	v := EditorProjectValues{TabSize: DefaultEditorTabSize, InsertSpaces: true, HeavyFolders: slices.Clone(DefaultHeavyFolders)}
	if s == nil {
		return v
	}
	if s.TabSize >= MinEditorTabSize && s.TabSize <= MaxEditorTabSize {
		v.TabSize = s.TabSize
	}
	if s.InsertSpaces != nil {
		v.InsertSpaces = *s.InsertSpaces
	}
	if s.HeavyFolders != nil {
		v.HeavyFolders = []string{}
		for _, n := range *s.HeavyFolders {
			n = strings.TrimSpace(n)
			if heavyFolderProblem(n) == "" && !slices.Contains(v.HeavyFolders, n) {
				v.HeavyFolders = append(v.HeavyFolders, n)
			}
		}
	}
	return v
}

// heavyFolderProblem answers why name cannot be a heavy folder, or "" when it can.
func heavyFolderProblem(name string) string {
	switch {
	case name == "":
		return "a heavy folder needs a name"
	case strings.Contains(name, "/"):
		return "heavy folder " + strconv.Quote(name) + " is a path — give a folder name; it is matched at any depth"
	case name == "." || name == "..":
		return "heavy folder " + strconv.Quote(name) + " is not a folder name"
	case name == ".git":
		return ".git is always heavy — it needs no row"
	}
	return ""
}

// validHeavyFolders trims each name and answers the list, or the first rule a name breaks.
func validHeavyFolders(names []string) ([]string, error) {
	out := make([]string, 0, len(names))
	for _, n := range names {
		n = strings.TrimSpace(n)
		if p := heavyFolderProblem(n); p != "" {
			return nil, UserError(p)
		}
		if slices.Contains(out, n) {
			return nil, UserError("heavy folder " + strconv.Quote(n) + " is listed twice")
		}
		out = append(out, n)
	}
	return out, nil
}
```

Patches — `EditorAppPatch` gains `ShowIgnored *bool`; `EditorProjectPatch` gains
`HeavyFolders *[]string`. In `UpdateEditorAppSettings`, the empty-patch guard becomes
`if p.FontSize == nil && p.WordWrap == nil && p.Autosave == nil && p.ShowIgnored == nil`, and
after the autosave block:

```go
	if p.ShowIgnored != nil {
		v := *p.ShowIgnored
		current.Editor.ShowIgnored = &v
	}
```

In `UpdateProjectEditorSettings`, the guard becomes
`if p.TabSize == nil && p.InsertSpaces == nil && p.HeavyFolders == nil`; validate before any
change, right after the tab-size check:

```go
	var heavy []string
	if p.HeavyFolders != nil {
		if heavy, err = validHeavyFolders(*p.HeavyFolders); err != nil {
			return err
		}
	}
```

and after the `InsertSpaces` block:

```go
	if p.HeavyFolders != nil {
		project.Editor.HeavyFolders = &heavy
	}
```

`LoadEditorSettings` fills the two new fields:

```go
	out.FontSize, out.WordWrap, out.Autosave, out.ShowIgnored = a.FontSize, a.WordWrap, a.Autosave, a.ShowIgnored
	…
	out.TabSize, out.InsertSpaces, out.HeavyFolders = pv.TabSize, pv.InsertSpaces, pv.HeavyFolders
```

`config_tree` already serialises `EditorAppValues` and `EditorProjectValues`, so it carries both
fields with no change to `configtree.go`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-ctx/`
Expected: PASS (the whole of both packages: the comparisons changed above must still pass).

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/editorsettings.go internal/wakilcore/editorsettings_test.go internal/wakilcore/configtree_test.go cmd/wakil-ctx/main_test.go
git commit -m "Settings: show ignored files and the heavy folders join the two editor tiers (3b-v part 2)"
```

---

### Task 2: wakilcore — the file listing takes the heavy names

**Files:**
- Modify: `internal/wakilcore/files.go:109-393` (listing) and `:588-612` (`SearchFiles`)
- Modify: `internal/wakilcore/files_test.go`

**Interfaces:**
- Consumes: `HeavyNames`, `DefaultHeavyFolders` (Task 1).
- Produces: `func ListFiles(ctx context.Context, root string, roots []string, heavy []string) (FileList, error)`,
  `func SearchFiles(ctx context.Context, roots []string, heavy []string, only []string, q SearchQuery) (SearchResult, error)`.
  `heavy` is the full name list, `.git` included (callers pass `HeavyNames(…)`). `HeavyDirs` and
  `isHeavyName` are removed.

- [ ] **Step 1: Write the failing tests** — in `internal/wakilcore/files_test.go`, add near the
  helpers:

```go
// testHeavy is 3b-ii's fixed list, which every listing test before 3b-v part 2 assumed.
var testHeavy = HeavyNames(DefaultHeavyFolders)
```

Append `, testHeavy` as the last argument of every existing `ListFiles(…)` call, and insert
`testHeavy, ` after the `roots` argument of every existing `SearchFiles(…)` call
(`SearchFiles(ctx, []string{a, b}, nil, q)` → `SearchFiles(ctx, []string{a, b}, testHeavy, nil, q)`).
`grep -n "ListFiles(\|SearchFiles(" internal/wakilcore/files_test.go` lists them (about 30).

Then add:

```go
// 3b-v part 2: the project's list decides which ignored folders are heavy; vendor, no longer
// named, is listed as ignored files.
func TestFilesListTakesTheProjectsHeavyFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "storage/\nvendor/\n")
	write(t, filepath.Join(a, "app.php"), "a")
	write(t, filepath.Join(a, "storage", "l.log"), "l")
	write(t, filepath.Join(a, "vendor", "autoload.php"), "v")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames([]string{"storage"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,storage" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "vendor/autoload.php" {
		t.Fatalf("ignored %v", got)
	}
}

// An empty project list leaves .git heavy.
func TestFilesListWithNoHeavyFoldersKeepsGitHeavy(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "vendor/\n")
	write(t, filepath.Join(a, "vendor", "autoload.php"), "v")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "vendor/autoload.php" {
		t.Fatalf("ignored %v", got)
	}
}

// Review Focus 2: a name is a folder name, not a pattern — "lib*" is heavy, "library" is not.
func TestAHeavyFolderNameIsMatchedLiterally(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "lib*/\n")
	write(t, filepath.Join(a, "lib*", "x.js"), "x")
	write(t, filepath.Join(a, "library", "y.js"), "y")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames([]string{"lib*"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,lib*" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "library/y.js" {
		t.Fatalf("ignored %v; library is not lib*", got)
	}
}

// A child repository of a folder of repositories takes the project's list too.
func TestAChildRepositoryTakesTheProjectsHeavyFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	api := filepath.Join(a, "api")
	if err := os.MkdirAll(api, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, api)
	write(t, filepath.Join(api, ".gitignore"), "dist/\n")
	write(t, filepath.Join(api, "main.go"), "m")
	write(t, filepath.Join(api, "dist", "out.js"), "o")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames([]string{"dist"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != "api/.git,api/dist" {
		t.Fatalf("heavy %v", got)
	}
}

// Spec: search skips ignored files either way — a folder taken off the list is listed as
// ignored, and still not searched.
func TestSearchSkipsAnIgnoredFolderThatIsNoLongerHeavy(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "vendor/\n")
	write(t, filepath.Join(a, "app.php"), "needle")
	write(t, filepath.Join(a, "vendor", "lib.php"), "needle")
	r, err := SearchFiles(context.Background(), []string{a}, HeavyNames(nil), nil, SearchQuery{Query: "needle"})
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Matches) != 1 || r.Matches[0].Path != "app.php" {
		t.Fatalf("matches %+v", r.Matches)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'FilesList|Search|HeavyFolder|ChildRepository'`
Expected: FAIL to compile — `too many arguments in call to ListFiles`.

- [ ] **Step 3: Implement** in `internal/wakilcore/files.go`

Delete `HeavyDirs` and `isHeavyName` (lines 135-147), keeping the comment's substance on the
`walked` type. `walked` carries the names:

```go
// walked is one listing in progress. heavy is the heavy folder names, .git first (3b-v part 2:
// the active project's list, HeavyNames); the non-git walk's skippedDirs stay built in.
type walked struct {
	files, ignored, heavy, repos []string
	heavyNames                   []string
}

func (w *walked) isHeavy(name string) bool { return slices.Contains(w.heavyNames, name) }

// underHeavy: some folder of rel, a "/"-separated path, is a heavy folder.
func (w *walked) underHeavy(rel string) bool {
	parts := strings.Split(strings.TrimSuffix(rel, "/"), "/")
	for _, p := range parts[:len(parts)-1] {
		if w.isHeavy(p) {
			return true
		}
	}
	return false
}

// globLiteral escapes a folder name for a glob pathspec, so a name holding * ? [ or \ matches
// only itself (Review Focus 2).
func globLiteral(name string) string {
	var b strings.Builder
	for _, r := range name {
		if strings.ContainsRune(`*?[\`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}
```

`gitListIgnored` and `gitListHeavy` take the names:

```go
func gitListIgnored(ctx context.Context, dir string, heavy []string) ([]string, error) {
	args := []string{"ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", "."}
	for _, h := range heavy {
		args = append(args, ":(exclude,glob)**/"+globLiteral(h)+"/**")
	}
	return gitLines(ctx, dir, args...)
}

func gitListHeavy(ctx context.Context, dir string, heavy []string) ([]string, error) {
	lines, err := gitLines(ctx, dir, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
	if err != nil {
		return nil, err
	}
	found := []string{".git"}
	for _, l := range lines {
		if strings.HasSuffix(l, "/") {
			d := strings.TrimSuffix(l, "/")
			if slices.Contains(heavy, filepath.Base(d)) {
				found = append(found, d)
			}
		}
	}
	return found, nil
}
```

Every other use moves to the `walked` value:
- `addIgnoredOf`: `if !underHeavy(f)` → `if !w.underHeavy(f)`.
- `addChildRepo`: `gitListIgnored(ctx, p)` → `gitListIgnored(ctx, p, w.heavyNames)`;
  `gitListHeavy(ctx, p)` → `gitListHeavy(ctx, p, w.heavyNames)`.
- `walkFiles(ctx, real string, heavy []string)`: starts `w := walked{heavyNames: heavy}`, and
  `if skippedDirs[d.Name()] || isHeavyName(d.Name())` becomes `if skippedDirs[d.Name()]` — the
  walk's list stays built in (spec, *What it does not do*); every old `HeavyDirs` name is in
  `skippedDirs` already.
- `ListFiles(ctx, root string, roots []string, heavy []string)`: `var w walked` becomes
  `w := walked{heavyNames: heavy}`; `gitListIgnored(ctx, real, heavy)`,
  `gitListHeavy(ctx, real, heavy)`; the walk branch calls `walkFiles(ctx, real, heavy)`. Its doc
  comment gains: "heavy is the heavy folder names, .git included (HeavyNames)."
- `SearchFiles(ctx, roots []string, heavy []string, only []string, q SearchQuery)`: passes
  `heavy` to `ListFiles(ctx, root, roots, heavy)`.

Add `"slices"` to the imports if `files.go` lacks it (it already uses `slices.Contains` in
`SearchFiles`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/`
Expected: PASS. (`cmd/wakil-files` does not compile until Task 3; do not run it here.)

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/files.go internal/wakilcore/files_test.go
git commit -m "Files: the listing takes the heavy folder names instead of a fixed list (3b-v part 2)"
```

---

### Task 3: wakil-ctx and wakil-files — the tools carry the settings

**Files:**
- Modify: `cmd/wakil-ctx/main.go:156-170` (args), `:490-515` (descriptions, patches)
- Modify: `cmd/wakil-ctx/main_test.go` (the editor-settings round trip near line 980)
- Modify: `cmd/wakil-files/main.go`
- Modify: `cmd/wakil-files/main_test.go`

**Interfaces:**
- Consumes: Task 1's patch fields; Task 2's `ListFiles`/`SearchFiles` signatures; `HeavyNames`.
- Produces: `set_editor_settings {showIgnored?: bool}`, `set_project_editor_settings
  {heavyFolders?: [string]}`, `editor_settings` answering `showIgnored` and `heavyFolders`.
  `files_list` and `files_search` use the active project's heavy folders.

- [ ] **Step 1: Write the failing tests**

In `cmd/wakil-ctx/main_test.go`'s editor-settings round trip, after the
`set_project_editor_settings` call that sets `tabSize`, add:

```go
	if res := call("set_editor_settings", map[string]any{"showIgnored": false}); res.IsError {
		t.Fatalf("set_editor_settings showIgnored: %s", textOf(t, res))
	}
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "heavyFolders": []string{"storage"}}); res.IsError {
		t.Fatalf("set_project_editor_settings heavyFolders: %s", textOf(t, res))
	}
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "heavyFolders": []string{".git"}}); !res.IsError {
		t.Fatal(".git was accepted as a heavy folder")
	}
```

and change the wanted value (made `reflect.DeepEqual` in Task 1) to
`wakilcore.EditorSettings{FontSize: 16, WordWrap: false, Autosave: "pause", ShowIgnored: false, TabSize: 2, InsertSpaces: true, HeavyFolders: []string{"storage"}}`.

In `cmd/wakil-files/main_test.go`, add (`"os/exec"` to the imports):

```go
// 3b-v part 2: files_list takes the active project's heavy folders from its project.json.
func TestFilesListUsesTheProjectsHeavyFolders(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	pp := filepath.Join(pdir, ".wakil", "project.json")
	body := `{"name":"proj","org":"initech","roots":[{"path":"."}],"environments":{"dev":{"databases":[]}},"editor":{"heavyFolders":["storage"]}}`
	if err := os.WriteFile(pp, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", pdir, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	for path, text := range map[string]string{".gitignore": "storage/\nvendor/\n.wakil/\n", "storage/l.log": "l", "vendor/a.php": "v"} {
		p := filepath.Join(pdir, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	res, list := callFiles(t, "files_list", map[string]any{"root": pdir})
	if res.IsError {
		t.Fatalf("files_list: %+v", res.Content)
	}
	if got := strings.Join(toStrings(list["heavy"]), ","); got != ".git,storage" {
		t.Fatalf("heavy %v", got)
	}
	if !slices.Contains(toStrings(list["ignored"]), "vendor/a.php") {
		t.Fatalf("ignored %v; vendor is not on this project's list", list["ignored"])
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./cmd/wakil-ctx/ -run EditorSettings` and `go test ./cmd/wakil-files/`
Expected: wakil-ctx FAIL (`showIgnored` is not a field the tool takes, or the settings read back
differ); wakil-files FAIL to compile (`not enough arguments in call to wakilcore.ListFiles`).

- [ ] **Step 3: Implement**

`cmd/wakil-ctx/main.go` — the two arg structs gain:

```go
	ShowIgnored *bool `json:"showIgnored,omitempty" jsonschema:"false hides gitignored files from the tree and from ⌘P; omit to leave unchanged"`
```

```go
	HeavyFolders *[]string `json:"heavyFolders,omitempty" jsonschema:"folder names, matched at any depth among the folders git ignores, listed but never walked or searched; the whole list, [] for none (.git is always heavy and is not listed); omit to leave unchanged"`
```

The patches pass them: `ShowIgnored: a.ShowIgnored` in `EditorAppPatch`, `HeavyFolders:
a.HeavyFolders` in `EditorProjectPatch`. The descriptions become:

- `editor_settings`: "Read the editor settings in force: font size, word wrap, autosave (off,
  pause or focus) and whether gitignored files are shown, from the operator's app-wide settings;
  tab size, tabs-or-spaces and the heavy folders (.git is always heavy besides) from the active
  project. Defaults fill anything unset. appError carries settings.json's error, whole, when it
  cannot be read; the defaults are then in force."
- `set_editor_settings`: "Change the app-wide editor settings: font size (9 to 24), word wrap,
  autosave (off, pause or focus), showIgnored. Read-modify-write: omit a field to leave it
  unchanged. Refuses an out-of-range value, and refuses to write over a settings.json that does
  not parse."
- `set_project_editor_settings`: "Change one project's editor settings: tab size (1 to 16),
  whether to indent with spaces, and the heavy folders (the whole list; each a folder name — no
  /, not . or .., not .git, no duplicates). Written to the project's project.json,
  read-modify-write; omit a field to leave it unchanged. A file's own indentation still wins in
  the editor. Refuses a project filed under another organisation."

`cmd/wakil-files/main.go` — replace `roots()` with:

```go
// project answers the active project's roots and its heavy folder names (.git, then the
// project's list — 3b-v part 2), or the tool error saying why there are none.
func project() ([]string, []string, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, nil, mcpx.ToolErr("wakil-files", err)
	}
	return wakilcore.ProjectRootPaths(*r), wakilcore.HeavyNames(r.Project.Editor.Resolved().HeavyFolders), nil
}

// roots answers the active project's roots, or the tool error saying why there are none.
func roots() ([]string, *mcp.CallToolResult) {
	rs, _, fail := project()
	return rs, fail
}
```

`files_list` and `files_search` call `rs, heavy, fail := project()` and pass `heavy`:
`wakilcore.ListFiles(ctx, a.Root, rs, heavy)`,
`wakilcore.SearchFiles(ctx, rs, heavy, a.Roots, wakilcore.SearchQuery{…})`. The other three
tools keep `roots()`.

Descriptions: in `files_list`, "the heavy folders vendor, node_modules and .git (heavy, never
walked)" becomes "the heavy folders — .git and the project's list, by default vendor and
node_modules (heavy, never walked)"; in `files_list_dir`, "how a heavy folder (vendor,
node_modules, .git) opens" becomes "how a heavy folder opens".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./cmd/wakil-ctx/ ./cmd/wakil-files/ ./internal/wakilcore/`
Expected: PASS. If `cmd/wakil-ctx/schema_test.go` pins tool descriptions or schemas, update the
pinned text to the new descriptions and re-run.

- [ ] **Step 5: Commit**

```bash
git add cmd/wakil-ctx/main.go cmd/wakil-ctx/main_test.go cmd/wakil-files/main.go cmd/wakil-files/main_test.go
git commit -m "Tools: the settings tools carry showIgnored and heavyFolders; wakil-files lists with the project's heavy folders (3b-v part 2)"
```

---

### Task 4: WakilKit — the settings types and the two writes

**Files:**
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift:109-151`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_set_editor_settings` near
  line 1020, `ctx_set_project_editor_settings` near line 1053)
- Modify: `app/Tests/WakilKitTests/EditorSettingsTests.swift`

**Interfaces:**
- Consumes: Task 3's tool fields and `editor_settings` keys.
- Produces: `SettingsEditor.showIgnored: Bool` (default `true`),
  `SettingsProjectEditor.heavyFolders: [String]` (default `["vendor", "node_modules"]`);
  `SettingsEditor.init(fontSize:wordWrap:autosave:showIgnored: Bool = true)`,
  `SettingsProjectEditor.init(tabSize:insertSpaces:heavyFolders: [String] = ["vendor", "node_modules"])`.
  `EditorSettings` (flat decode) picks both up through those two decoders with no change.

- [ ] **Step 1: Write the failing tests** — append to `EditorSettingsTests`:

```swift
    @Test func thePartTwoKeysDecodeAndDefault() throws {
        let json = #"{"structuredContent":{"fontSize":12,"wordWrap":false,"autosave":"off","showIgnored":false,"tabSize":4,"insertSpaces":true,"heavyFolders":["storage"]}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let s = try #require(decodeEditorSettings(fromResult: value))
        #expect(s.app.showIgnored == false)
        #expect(s.project.heavyFolders == ["storage"])
        let older = #"{"structuredContent":{"fontSize":12,"wordWrap":false,"autosave":"off","tabSize":4,"insertSpaces":true}}"#
        let o = try #require(decodeEditorSettings(fromResult: try JSONDecoder().decode(JSONValue.self, from: Data(older.utf8))))
        #expect(o.app.showIgnored == true)
        #expect(o.project.heavyFolders == ["vendor", "node_modules"])
    }

    /// An empty list is a value: only .git is heavy.
    @Test func anEmptyHeavyFolderListDecodesEmpty() throws {
        let json = #"{"structuredContent":{"tabSize":4,"insertSpaces":true,"heavyFolders":[]}}"#
        let s = try #require(decodeEditorSettings(fromResult: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        #expect(s.project.heavyFolders == [])
    }

    @Test func theWritesForwardShowIgnoredAndTheHeavyFolders() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_editor_settings", params: .object(["showIgnored": .bool(false)]),
            origin: .ui, environment: "staging", confirmation: nil)
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"),
                             "heavyFolders": .array([.string("storage"), .string("dist")])]),
            origin: .ui, environment: "staging", confirmation: nil)
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"), "heavyFolders": .array([.string("a"), .integer(3)])]),
            origin: .ui, environment: "staging", confirmation: nil)
        let calls = await caller.recorded()
        #expect(calls.count == 3)
        #expect(calls[0].arguments == .object(["showIgnored": .bool(false)]))
        #expect(calls[1].arguments == .object([
            "projectPath": .string("/p.json"), "heavyFolders": .array([.string("storage"), .string("dist")]),
        ]))
        // A list holding anything but strings is not Go's shape: it is not forwarded.
        #expect(calls[2].arguments == .object(["projectPath": .string("/p.json")]))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter EditorSettingsTests`
Expected: FAIL to compile — `value of type 'SettingsEditor' has no member 'showIgnored'`.

- [ ] **Step 3: Implement**

`SettingsTree.swift` — `SettingsEditor`:

```swift
public struct SettingsEditor: Sendable, Equatable, Decodable {
    public var fontSize: Int
    public var wordWrap: Bool
    public var autosave: EditorAutosaveMode
    /// Off hides gitignored files from the tree and ⌘P (3b-v part 2). On by default.
    public var showIgnored: Bool

    public static let defaults = SettingsEditor(fontSize: 12, wordWrap: false, autosave: .off)

    public init(fontSize: Int, wordWrap: Bool, autosave: EditorAutosaveMode, showIgnored: Bool = true) {
        self.fontSize = fontSize
        self.wordWrap = wordWrap
        self.autosave = autosave
        self.showIgnored = showIgnored
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? Self.defaults.fontSize
        wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? Self.defaults.wordWrap
        autosave = (try c.decodeIfPresent(String.self, forKey: .autosave)).flatMap(EditorAutosaveMode.init(rawValue:)) ?? .off
        showIgnored = try c.decodeIfPresent(Bool.self, forKey: .showIgnored) ?? Self.defaults.showIgnored
    }

    private enum CodingKeys: String, CodingKey { case fontSize, wordWrap, autosave, showIgnored }
}
```

`SettingsProjectEditor`:

```swift
public struct SettingsProjectEditor: Sendable, Equatable, Decodable {
    public var tabSize: Int
    public var insertSpaces: Bool
    /// The heavy folders besides .git, which is always heavy (3b-v part 2). Empty is a value.
    public var heavyFolders: [String]

    public static let defaults = SettingsProjectEditor(tabSize: 4, insertSpaces: true)

    public init(tabSize: Int, insertSpaces: Bool, heavyFolders: [String] = ["vendor", "node_modules"]) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.heavyFolders = heavyFolders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabSize = try c.decodeIfPresent(Int.self, forKey: .tabSize) ?? Self.defaults.tabSize
        insertSpaces = try c.decodeIfPresent(Bool.self, forKey: .insertSpaces) ?? Self.defaults.insertSpaces
        heavyFolders = try c.decodeIfPresent([String].self, forKey: .heavyFolders) ?? Self.defaults.heavyFolders
    }

    private enum CodingKeys: String, CodingKey { case tabSize, insertSpaces, heavyFolders }
}
```

`StandardActions.swift` — `ctx_set_editor_settings`: the schema's properties gain
`"showIgnored": .object(["type": .string("boolean")])`; the handler gains
`if case .bool? = fields["showIgnored"] { arguments["showIgnored"] = fields["showIgnored"] }`;
the description gains "showIgnored (false hides gitignored files from the tree and ⌘P)".

`ctx_set_project_editor_settings`: the schema gains
`"heavyFolders": .object(["type": .string("array"), "items": .object(["type": .string("string")])])`;
the handler gains:

```swift
            // The whole list, and only when every entry is a string — Go's []string.
            if case .array(let items)? = fields["heavyFolders"],
               items.allSatisfy({ if case .string = $0 { true } else { false } }) {
                arguments["heavyFolders"] = .array(items)
            }
```

and the description gains "heavyFolders (the whole list of folder names; .git is always heavy)".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorSettingsTests|StandardActionsTests|ActionClassificationTests'`
Expected: PASS. If a test pins an action's schema or description text, update it to match.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/SettingsTree.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/EditorSettingsTests.swift
git commit -m "Settings: WakilKit decodes and forwards showIgnored and heavyFolders (3b-v part 2)"
```

---

### Task 5: WakilKit — the tree, ⌘P and the re-list

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorTree.swift` (`editorTreeRows`)
- Modify: `app/Sources/WakilKit/Command/PaletteSources.swift` (`FilesSource`, near line 510)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`paletteOpenSources` near line 5460;
  `saveProjectEditorSettings` near line 2590)
- Modify: `app/Tests/WakilKitTests/EditorTreeTests.swift`,
  `app/Tests/WakilKitTests/PaletteFilesSourceTests.swift`,
  `app/Tests/WakilKitTests/WindowModelEditorTests.swift`

**Interfaces:**
- Consumes: `WindowModel.editorSettings.app.showIgnored` (Task 4).
- Produces: `editorTreeRows(_:open:dirs:loading:dirErrors:showIgnored: Bool = true)`;
  `FilesSource.init(files:roots:showIgnored: @escaping @Sendable () async -> Bool = { true })`.
  Task 6 passes `showIgnored` to `editorTreeRows` from `EditorPane`.

- [ ] **Step 1: Write the failing tests**

`EditorTreeTests.swift`:

```swift
// 3b-v part 2: show ignored files off drops them from the tree; heavy folders stay.
@Test func hidingIgnoredFilesDropsThemAndKeepsTheHeavyFolders() {
    let l = listing("/p/api", files: ["a.go"], ignored: [".env", "storage/l.log"], heavy: [".git", "vendor"])
    let rows = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:], showIgnored: false)
    #expect(names(rows) == ["api", " .git~", " vendor~", " a.go"])
}

// Review Focus 4.
@Test func hidingIgnoredFilesMovesTheSelectionOffAHiddenRow() {
    let l = listing("/p/api", files: ["a.go", "b.go"], ignored: [".env"])
    let before = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    let after = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:], showIgnored: false)
    #expect(editorTreeSelection(after: "/p/api/.env", previous: before, now: after) == "/p/api/a.go")
}
```

`PaletteFilesSourceTests.swift`:

```swift
@Test func ignoredFilesAreLeftOutWhenTheSettingIsOff() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["config/env.php"])
    await files.setIgnored("/p/api", [".env"])
    let rows = await FilesSource(files: files, roots: { ["/p/api"] }, showIgnored: { false }).entries()
    #expect(rows.map(\.title) == ["env.php"])
}
```

`WindowModelEditorTests.swift`, inside `WindowModelEditorTests`:

```swift
    /// A stub for the project write, so a save lands without a wakil-ctx.
    private func stubProjectWrite(_ model: WindowModel, refuse: Bool = false) async {
        await model.registryForTesting.register(Action(
            name: "ctx_set_project_editor_settings", description: "stub", kind: .control, audience: .operatorOnly,
            schema: .object([:]),
            handler: { _ in
                if refuse { throw StandardActionError.missingParam(action: "ctx_set_project_editor_settings", param: "heavyFolders") }
                return .object([:])
            }))
    }

    // 3b-v part 2: the heavy folders decide what each root lists, so a save re-lists every root.
    @Test func savingTheHeavyFoldersRelistsEveryRoot() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api", "/p/portal"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        await stubProjectWrite(model)
        let before = await files.calls.filter { $0 == "files_list /p/api" }.count
        let refusal = await model.saveProjectEditorSettings(
            projectPath: "/p.json", ["heavyFolders": .array([.string("storage")])])
        #expect(refusal == nil)
        while await files.calls.filter({ $0 == "files_list /p/api" }).count <= before { await Task.yield() }
    }

    @Test func savingTheTabSizeRelistsNothing() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        await stubProjectWrite(model)
        let before = await files.calls.filter { $0 == "files_list /p/api" }.count
        _ = await model.saveProjectEditorSettings(projectPath: "/p.json", ["tabSize": .integer(2)])
        for _ in 0..<50 { await Task.yield() }
        #expect(await files.calls.filter { $0 == "files_list /p/api" }.count == before)
    }

    // Review Focus 5.
    @Test func aRefusedHeavyFolderWriteRelistsNothing() async throws {
        let (model, _, files) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshContext()
        await files.setListing("/p/api", ["a.go"])
        await model.openPane(kind: "editor")
        await model.toggleEditorColumn(.files)
        await stubProjectWrite(model, refuse: true)
        let before = await files.calls.filter { $0 == "files_list /p/api" }.count
        let refusal = await model.saveProjectEditorSettings(
            projectPath: "/p.json", ["heavyFolders": .array([.string("dist"), .string("dist")])])
        #expect(refusal != nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(await files.calls.filter { $0 == "files_list /p/api" }.count == before)
    }
```

If `ActionRegistry.register` refuses a name already registered, `editorWindowParts` registers no
`ctx_*` action, so the stub is the only one. If `Action`'s initialiser differs from the call
above, copy the shape from `registerStandardActions`' `ctx_set_project_editor_settings` (same
labels), and say so in the report.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorTreeTests|PaletteFilesSourceTests|WindowModelEditorTests'`
Expected: FAIL to compile — `extra argument 'showIgnored' in call`; then (once compiling)
`savingTheHeavyFoldersRelistsEveryRoot` hangs on its wait (bound the run with the harness's
timeout, or run it after Step 3).

- [ ] **Step 3: Implement**

`EditorTree.swift` — `editorTreeRows` gains the parameter and skips the ignored list:

```swift
/// `showIgnored` false (3b-v part 2) leaves gitignored files out; heavy folders stay, because
/// the tree is how one is opened.
public func editorTreeRows(_ listings: [EditorRootListing], open: Set<String>,
                           dirs: [String: [EditorDirEntry]], loading: Set<String>,
                           dirErrors: [String: String], showIgnored: Bool = true) -> [EditorTreeRow] {
```

and `for f in l.ignored { insert(f, into: trie, ignored: true) }` becomes
`if showIgnored { for f in l.ignored { insert(f, into: trie, ignored: true) } }`.

`PaletteSources.swift` — `FilesSource`:

```swift
    private let showIgnored: @Sendable () async -> Bool

    /// `showIgnored` answers the operator's setting (3b-v part 2): false leaves the gitignored
    /// files out rather than listing them dimmed.
    public init(files: any ToolCaller, roots: @escaping @Sendable () async -> [String],
                showIgnored: @escaping @Sendable () async -> Bool = { true }) {
        self.files = files
        self.roots = roots
        self.showIgnored = showIgnored
    }
```

In `entries()`, read it once before the loop — `let withIgnored = await showIgnored()` — and
change the row loop to:

```swift
            for (paths, dimmed) in [(list, false), (withIgnored ? ignored : [], true)] {
```

The truncation note still counts `list.count + ignored.count`: the cap counts both whether or
not the ignored ones are shown, and the note says how many were listed.

`WindowModel.swift`, `paletteOpenSources` — the files source reads the setting each time ⌘P
builds:

```swift
        let fileSource: FilesSource? = paletteClients.files.map { files in
            FilesSource(files: files, roots: { [weak self] in await self?.gitRootPaths ?? [] },
                        showIgnored: { [weak self] in await self?.editorSettings.app.showIgnored ?? true })
        }
```

`WindowModel.swift`, `saveProjectEditorSettings`:

```swift
    /// Saves one project's editor fields into its project.json. A heavy-folder change that lands
    /// re-lists every root, as a disk wake does: the list decides what each root lists (3b-v
    /// part 2). The re-list covers the active project's roots whichever project was written — a
    /// spare re-list costs one `files_list` per root, and the window does not hold project paths
    /// to compare.
    public func saveProjectEditorSettings(projectPath: String, _ fields: [String: JSONValue]) async -> String? {
        var params = fields
        params["projectPath"] = .string(projectPath)
        let refusal = await saveEditorSettings(action: "ctx_set_project_editor_settings", params: .object(params))
        if refusal == nil, fields["heavyFolders"] != nil {
            for root in gitRootPaths { await editorRootChanged(root, paths: nil) }
        }
        return refusal
    }
```

Show-ignored needs no re-list: the tree and ⌘P filter what the list already holds, and
`editorSettings` is re-read after every settings write (part 1's `saveEditorSettings`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorTreeTests|PaletteFilesSourceTests|WindowModelEditorTests|WindowModelPaletteTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorTree.swift app/Sources/WakilKit/Command/PaletteSources.swift app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/EditorTreeTests.swift app/Tests/WakilKitTests/PaletteFilesSourceTests.swift app/Tests/WakilKitTests/WindowModelEditorTests.swift
git commit -m "Editor: the tree and ⌘P leave ignored files out when asked; a heavy-folder save re-lists every root (3b-v part 2)"
```

---

### Task 6: WakilApp — the two rows and the tree's setting

WakilApp has no test target. This task is verified by `make app-build` building and by the Cover rung's e2e
checks; the reviewer reads it against PRODUCT.md §Interaction Rules 1, 2, 3, 6 and 8.

**Files:**
- Modify: `app/Sources/WakilApp/EditorSettingsForms.swift`
- Modify: `app/Sources/WakilApp/EditorPane.swift:17, 84-85`
- Modify: `app/Sources/WakilApp/Canvas.swift:~450` (where `EditorPane` is built)

**Interfaces:**
- Consumes: `SettingsEditor.showIgnored`, `SettingsProjectEditor.heavyFolders` (Task 4);
  `editorTreeRows(…, showIgnored:)` (Task 5); `ChoiceSettingRow`, `SettingsScale`,
  `SettingsPalette` (part 1).
- Produces: accessibility identifiers, for the e2e auditor:
  `settings.editor.showIgnored.on` / `.off` / `.refusal`;
  `settings.projectEditor.heavy.git` (the fixed row);
  `settings.projectEditor.heavy.<i>` (row *i*'s field), `settings.projectEditor.heavy.<i>.remove`;
  `settings.projectEditor.heavy.new` (the added row's field);
  `settings.projectEditor.heavy.add`; `settings.projectEditor.heavy.refusal`.
  Identifiers carry an index, never a folder name (part 1's harvest-safety ruling).

- [ ] **Step 1: Show ignored files** — in `EditorAppSettingsForm`, after the Autosave row:

```swift
            ChoiceSettingRow(
                label: "Show ignored files", options: ["Off", "On"], selected: editor.showIgnored ? "On" : "Off",
                identifier: { option in
                    let key = option.lowercased()
                    return "settings.editor.showIgnored.\(key)"
                },
                refusalIdentifier: "settings.editor.showIgnored.refusal",
                save: { option in await save(["showIgnored": .bool(option == "On")]) })
```

- [ ] **Step 2: The heavy-folder list** — add to `EditorSettingsForms.swift`:

```swift
/// A project's heavy folders (3b-v part 2): `.git` first, fixed, then one name per row. A row
/// writes when focus leaves it or on Return (Rule 2); *Add folder* adds an empty row, focused
/// (Rule 3); × writes the list without that row at once — adding it back undoes it (Rule 1). A row
/// left empty writes nothing and goes away; a refused name keeps its text and shows Go's sentence
/// under the list (Rule 8). Every write sends the whole list.
struct HeavyFoldersSettingRow: View {
    let folders: [String]
    let save: ([String]) async -> String?

    @State private var drafts: [Int: String] = [:]
    /// The added row's text; nil when there is no added row.
    @State private var adding: String?
    @State private var refusal: String?
    @State private var inFlight = false
    /// A row's index; `folders.count` is the added row.
    @FocusState private var focused: Int?

    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HEAVY FOLDERS")
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
            HStack(spacing: 8) {
                Text(".git")
                    .font(.system(size: SettingsScale.body, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.50))
                Text("always")
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(coolWhite.opacity(0.30))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.projectEditor.heavy.git")
            ForEach(Array(folders.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 8) {
                    field(text: Binding(get: { drafts[i] ?? name }, set: { drafts[i] = $0 }), row: i)
                        .accessibilityIdentifier("settings.projectEditor.heavy.\(i)")
                    Button {
                        var next = folders
                        next.remove(at: i)
                        write(next)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: SettingsScale.meta))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(coolWhite.opacity(0.40))
                    .disabled(inFlight)
                    .accessibilityLabel("Remove \(name)")
                    .accessibilityIdentifier("settings.projectEditor.heavy.\(i).remove")
                }
            }
            if adding != nil {
                field(text: Binding(get: { adding ?? "" }, set: { adding = $0 }), row: folders.count)
                    .accessibilityIdentifier("settings.projectEditor.heavy.new")
                    .onAppear { focused = folders.count }
            } else {
                Button("Add folder") {
                    refusal = nil
                    adding = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(coolWhite.opacity(0.60))
                .disabled(inFlight)
                .accessibilityIdentifier("settings.projectEditor.heavy.add")
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.projectEditor.heavy.refusal")
            }
        }
        .padding(.bottom, 4)
    }

    private func field(text: Binding<String>, row: Int) -> some View {
        TextField("folder name", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: SettingsScale.body, design: .monospaced))
            .foregroundStyle(coolWhite.opacity(0.88))
            .frame(width: 180)
            .focused($focused, equals: row)
            .onSubmit { commit(row) }
            .onChange(of: focused) { was, now in if was == row, now != row { commit(row) } }
    }

    private func commit(_ row: Int) {
        guard !inFlight else { return }
        if row == folders.count {
            let name = (adding ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                adding = nil
                refusal = nil
                return
            }
            write(folders + [name])
            return
        }
        guard row < folders.count, let text = drafts[row]?.trimmingCharacters(in: .whitespaces),
              text != folders[row] else {
            drafts[row] = nil
            return
        }
        var next = folders
        if text.isEmpty { next.remove(at: row) } else { next[row] = text }
        write(next)
    }

    /// The typed text stays until the save lands: a success clears it (the list is re-read), a
    /// refusal keeps it beside its sentence. `inFlight` makes Return then focus-leave write once.
    private func write(_ next: [String]) {
        inFlight = true
        Task {
            let answer = await save(next)
            inFlight = false
            refusal = answer
            if answer == nil {
                drafts = [:]
                adding = nil
            }
        }
    }
}
```

In `EditorProjectSettingsForm`, after the Indent row and before the footnote:

```swift
            HeavyFoldersSettingRow(
                folders: editor.heavyFolders,
                save: { names in await save(["heavyFolders": .array(names.map { .string($0) })]) })
```

and extend the footnote:

```swift
            Text("A file's own indentation wins; these apply to new files and files with none. "
                 + "Heavy folders are the folders git ignores with these names, at any depth: listed, "
                 + "never walked or searched, opened one at a time. "
                 + "Stored in this project's project.json, so they travel with the code.")
```

The form is already keyed `.id(project.path)` in `SettingsPane.swift:446`, so the rows' drafts do
not carry from one project to another.

- [ ] **Step 3: The tree reads the setting** — `EditorPane.swift` gains `let showIgnored: Bool`
  beside `viewOptions` (line 17), and `treeRows` passes it:

```swift
        editorTreeRows(roots.compactMap { files.listings[$0] }, open: Set(column.open), dirs: files.dirs,
                       loading: files.loading, dirErrors: files.dirErrors, showIgnored: showIgnored)
```

`Canvas.swift`, where `EditorPane(` is built (beside `viewOptions: model.editorSettings.viewOptions`):
add `showIgnored: model.editorSettings.app.showIgnored,` in the parameter order the struct
declares. `grep -rn "EditorPane(" app/Sources/WakilApp` lists every construction; each gains it.

- [ ] **Step 4: Build**

Run: `make app-build`
Expected: build succeeds with no new warnings in the touched files.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/EditorSettingsForms.swift app/Sources/WakilApp/EditorPane.swift app/Sources/WakilApp/Canvas.swift
git commit -m "Settings: the Show ignored files row and the heavy-folder list; the tree reads the setting (3b-v part 2)"
```

---

### Task 7: Docs, as built

**Files:**
- Modify: `docs/wakil/design-language.md:589`
- Modify: `docs/architecture/go.md:89-98`
- Modify: `docs/architecture/wakilkit.md:192-199`

- [ ] **Step 1: Edit**

- `design-language.md:589` — "First settings: the editor's font size, word wrap and autosave."
  becomes "Its settings: the editor's font size, word wrap, autosave and whether gitignored files
  are shown."
- `go.md` `files_list` entry — the heavy folders are ".git and the active project's
  `editor.heavyFolders` (default `vendor`, `node_modules`; 3b-v)"; outside a repository the walk's
  built-in `skippedDirs` are heavy. Add one line under the editor-settings tools (from part 1)
  naming `showIgnored` and `heavyFolders`.
- `wakilkit.md` `EditorTree.swift` entry — "`editorTreeRows` leaves ignored files out when
  `showIgnored` is false (3b-v)". Under the palette sources, `FilesSource` does the same.

- [ ] **Step 2: Commit**

```bash
git add docs/wakil/design-language.md docs/architecture/go.md docs/architecture/wakilkit.md
git commit -m "Docs: 3b-v part 2 as built (3b-v part 2)"
```

---

## After the last task (controller only)

1. `make build && make test && make app-test` — all green, run by the controller.
2. **Cover:** the repo's e2e auditor (`docs/agents/e2e.md`) on this branch. The spec's part 2
   checks: hiding ignored files removes `.env` from the tree and ⌘P; adding a heavy folder makes
   it list only when opened; an invalid heavy folder shows its refusal and writes nothing.
   `make e2e-new`, then `make e2e`. **Ask the operator and message the peer Wakil sessions
   before any GUI or e2e run.**
3. **Walk:** extend `docs/wakil/phase-3b-v-acceptance.md` with part 2's rows (show ignored on/off
   in the tree and ⌘P; add, rename, remove a heavy folder; remove all; a refused duplicate), render
   the machine section, and hand it to the operator.
