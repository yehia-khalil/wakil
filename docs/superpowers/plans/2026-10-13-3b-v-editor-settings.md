# 3b-v Part 1: Editor Settings (font size, wrap, tabs, autosave) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator sets the editor's font size, word wrap and autosave once for all of Wakil,
and each project's tab size and tabs-or-spaces, from two new Editor nodes in the Settings pane;
open editors pick the change up at once, and autosave saves dirty file tabs after a pause or
when focus leaves.

**Architecture:** Go owns both tiers. A new `internal/wakilcore/editorsettings.go` reads and
patches `~/.wakil/settings.json` (app-wide) and a new `editor` block in `project.json` (per
project), read-modify-write from disk. `wakil-ctx` exposes one read and two writes; WakilKit
registers them as `ctx_*` actions (the writes operator-only, Decision 30), the window holds the
resolved `EditorSettings`, and a pure `EditorAutosave` unit decides which tabs to save. WakilApp
draws the forms and carries the options to Monaco.

**Tech Stack:** Go 1.x + `modelcontextprotocol/go-sdk` (wakil-ctx), Swift 6 / SwiftUI / Swift
Testing (WakilKit, WakilApp), Monaco in a `WKWebView`.

**Spec:** `docs/superpowers/specs/2026-10-13-3b-v-editor-settings-design.md`

**Scope of this plan — part 1 only.** Font size, word wrap, autosave (app-wide) and tab size,
tabs-or-spaces (per project). **Part 2** — show ignored files and heavy folders — changes code
3b-ii is still writing and gets its own plan after 3b-ii merges (spec, *Decisions*: "Built in
two parts"). This plan adds no field for those two at any layer.

## Global Constraints

- Two tiers: app-wide in `~/.wakil/settings.json` under an `editor` key; per project in
  `project.json` under `editor`. A missing file, key or field reads as its default. No migration.
- Font size 9–24, default 12. Word wrap default off. Autosave `off` | `pause` | `focus`, default
  `off`. Tab size 1–16, default 4. Indent default spaces (`insertSpaces: true`).
- Every write is read-modify-write from disk at dispatch; a refused write writes nothing.
- Both writes are `.control` and `.operatorOnly` (Decision 30). The read is `.read` and
  `.agentReachable`.
- **Action names use the `ctx_` prefix** (`ctx_editor_settings`, `ctx_set_editor_settings`,
  `ctx_set_project_editor_settings`), not the spec's `settings_editor_*`: `WindowModel.writesSettings`
  recognises settings writes by the `ctx_` prefix, and the existing settings actions all use it.
- A file's own indentation wins: Monaco detects indentation, and the project's values are only the
  fallback.
- Autosave never writes a scratch tab, a tab marked *changed on disk* or *deleted*, a read-only
  tab, or a tab whose save is in flight. It dispatches the existing `editor_save`.
- Pause delay is 1 second.
- No `Co-Authored-By` or "Generated with" lines in any commit (operator rule).
- Commit message style: `<Area>: <what> (3b-v PR n)`, as in `git log`.
- Go tests: `go test ./internal/wakilcore/ -run <Name>` and `go test ./cmd/wakil-ctx/ -run <Name>`.
  Swift tests: `cd app && ../scripts/swift-test.sh --filter <Name>`. Run `make build` before any
  Swift test run that depends on Go changes (`make app-test` does not build Go). **An implementer
  subagent runs only scoped filters; the controller runs `make test` and `make app-test`.**

## Review Focus

1. **A hand-edited `settings.json` with an out-of-range or unknown value** (font size 40,
   autosave `"always"`) — the editor should use the default for that field, not crash or send 40
   to Monaco. Pinned in Task 1 (`TestResolvedIgnoresOutOfRangeValues`).
2. **A malformed `settings.json`** — the pane should show the parse error, the editor should use
   defaults, and a write from the pane should be refused rather than overwrite the file. Pinned in
   Task 1 (`TestAMalformedSettingsFileRefusesAWrite`) and Task 2 (`editorError` in the tree).
3. **A tab closed, or saved by ⌘S, before its pause timer fires** — nothing is written and nothing
   errors. Pinned in Task 6 (`aTabClosedBeforeThePauseEndsIsNotWritten`).
4. **⌘S in flight when the pause ends** — autosave must not start a second write. Pinned in
   Task 6 (`autosaveDoesNotFireWhileASaveIsInFlight`).
5. **A project write for a project filed under another organisation** — refused, nothing written.
   Pinned in Task 1 (`TestAProjectInAnotherOrgIsNotWritten`).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `internal/wakilcore/editorsettings.go` | create | The two tiers' types, defaults, load, resolve, validate, patch |
| `internal/wakilcore/editorsettings_test.go` | create | Its tests |
| `internal/wakilcore/config.go` | modify | `Project.Editor` |
| `internal/wakilcore/configtree.go` | modify | `ConfigTree.Editor`, `EditorError`, `ConfigTreeProject.Editor` |
| `internal/wakilcore/configtree_test.go` | modify | The new fields |
| `cmd/wakil-ctx/main.go` | modify | `editor_settings`, `set_editor_settings`, `set_project_editor_settings` |
| `cmd/wakil-ctx/schema_test.go`, `cmd/wakil-ctx/main_test.go` | modify | Tool list; a round trip |
| `app/Sources/WakilKit/Panes/SettingsTree.swift` | modify | `SettingsEditor`, `SettingsProjectEditor`, decoded into the tree |
| `app/Sources/WakilKit/Editor/EditorSettings.swift` | create | `EditorSettings` (resolved, both tiers), `EditorViewOptions`, `EditorAutosaveMode`, decoder |
| `app/Sources/WakilKit/Editor/EditorAutosave.swift` | create | Pure decision: which tabs to arm or save |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | modify | The three actions |
| `app/Sources/WakilKit/MCP/PermissionPrompt.swift` | modify | `operatorOnlyActions`, denial sentence |
| `app/Sources/WakilKit/App/WindowModel.swift` | modify | `editorSettings`, refresh, save wrappers, autosave wiring |
| `app/Sources/WakilApp/monaco-host.html` | modify | `wakilSetOptions`, `wakilSetFontSize` |
| `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `MonacoDiffRenderer.swift` | modify | Bridges |
| `app/Sources/WakilApp/EditorPane.swift`, `GitPane.swift`, `Canvas.swift` | modify | Pass options down |
| `app/Sources/WakilApp/EditorSettingsForms.swift` | create | The two Editor forms |
| `app/Sources/WakilApp/SettingsPane.swift` | modify | Two nodes, breadcrumbs, the forms |
| `app/Sources/WakilApp/AppScene.swift` | modify | Resign-active → autosave |
| `app/Tests/WakilKitTests/EditorSettingsTests.swift`, `EditorAutosaveTests.swift` | create | Swift tests |
| `docs/wakil/decisions.md`, `docs/wakil/design-language.md`, `docs/architecture/*.md` | modify | Decision 38, §14, file maps |

---

### Task 1: wakilcore — the two tiers

**Files:**
- Create: `internal/wakilcore/editorsettings.go`
- Create: `internal/wakilcore/editorsettings_test.go`
- Modify: `internal/wakilcore/config.go:12-18` (the `Project` struct)

**Interfaces:**
- Consumes: `WakilDir()` (`paths.go`), `writeFileAtomic` (`paths.go:161`), `LoadProject`,
  `SaveProject`, `CurrentOrg`, `Resolve`, `UserError`.
- Produces:
  - consts `AutosaveOff`, `AutosavePause`, `AutosaveFocus`, `DefaultEditorFontSize`,
    `MinEditorFontSize`, `MaxEditorFontSize`, `DefaultEditorTabSize`, `MinEditorTabSize`,
    `MaxEditorTabSize`
  - `type AppSettings struct{ Editor EditorAppSettings }`
  - `type EditorAppSettings struct{ FontSize int; WordWrap bool; Autosave string }`
  - `type EditorProjectSettings struct{ TabSize int; InsertSpaces *bool }`
  - `type EditorAppValues struct{ FontSize int; WordWrap bool; Autosave string }` (JSON
    `fontSize`, `wordWrap`, `autosave`)
  - `type EditorProjectValues struct{ TabSize int; InsertSpaces bool }` (JSON `tabSize`,
    `insertSpaces`)
  - `type EditorSettings struct{ FontSize int; WordWrap bool; Autosave string; TabSize int; InsertSpaces bool; AppError string }`
  - `func (EditorAppSettings) Resolved() EditorAppValues`
  - `func (*EditorProjectSettings) Resolved() EditorProjectValues` (nil receiver allowed)
  - `func LoadAppSettings() (AppSettings, error)`
  - `type EditorAppPatch struct{ FontSize *int; WordWrap *bool; Autosave *string }`
  - `func UpdateEditorAppSettings(EditorAppPatch) error`
  - `type EditorProjectPatch struct{ TabSize *int; InsertSpaces *bool }`
  - `func UpdateProjectEditorSettings(projectPath string, p EditorProjectPatch) error`
  - `func LoadEditorSettings() EditorSettings`
  - `Project.Editor *EditorProjectSettings` (JSON `editor`, omitempty)

- [ ] **Step 1: Write the failing tests**

`internal/wakilcore/editorsettings_test.go`:

```go
package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func intp(v int) *int       { return &v }
func boolp(v bool) *bool    { return &v }
func strp(v string) *string { return &v }

func appSettingsFile(t *testing.T) string {
	t.Helper()
	dir, err := WakilDir()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, appSettingsFileName)
}

// No file is the ordinary case on an existing install: every value is its default.
func TestNoSettingsFileReadsAsDefaults(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	got := s.Editor.Resolved()
	want := EditorAppValues{FontSize: 12, WordWrap: false, Autosave: AutosaveOff}
	if got != want {
		t.Errorf("Resolved() = %+v, want %+v", got, want)
	}
}

// Review Focus 1: a hand edit outside the range falls back to the default rather than reaching
// Monaco.
func TestResolvedIgnoresOutOfRangeValues(t *testing.T) {
	got := EditorAppSettings{FontSize: 40, Autosave: "always"}.Resolved()
	if got.FontSize != DefaultEditorFontSize || got.Autosave != AutosaveOff {
		t.Errorf("Resolved() = %+v; out-of-range values must read as defaults", got)
	}
	var p *EditorProjectSettings
	if v := p.Resolved(); v != (EditorProjectValues{TabSize: 4, InsertSpaces: true}) {
		t.Errorf("nil project Resolved() = %+v", v)
	}
	if v := (&EditorProjectSettings{TabSize: 0, InsertSpaces: boolp(false)}).Resolved(); v.TabSize != 4 || v.InsertSpaces {
		t.Errorf("Resolved() = %+v", v)
	}
}

// Read-modify-write: a patch changes only the fields it names.
func TestUpdateEditorAppSettingsWritesOnlyWhatItWasGiven(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{WordWrap: boolp(true)}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(14)}); err != nil {
		t.Fatal(err)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Editor.Resolved(); got != (EditorAppValues{FontSize: 14, WordWrap: true, Autosave: AutosaveOff}) {
		t.Errorf("Resolved() = %+v", got)
	}
}

func TestUpdateEditorAppSettingsRefusesOutOfRangeAndWritesNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, p := range []EditorAppPatch{
		{FontSize: intp(8)}, {FontSize: intp(25)}, {Autosave: strp("always")},
	} {
		err := UpdateEditorAppSettings(p)
		if err == nil {
			t.Fatalf("patch %+v was accepted", p)
		}
		if _, ok := IsUserError(err); !ok {
			t.Errorf("patch %+v: %v is not a UserError", p, err)
		}
	}
	if _, err := os.Stat(appSettingsFile(t)); !os.IsNotExist(err) {
		t.Errorf("a refused write created settings.json (stat err %v)", err)
	}
}

func TestTheRangeEdgesAreAccepted(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, n := range []int{9, 24} {
		if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(n)}); err != nil {
			t.Errorf("font size %d: %v", n, err)
		}
	}
	for _, mode := range []string{AutosaveOff, AutosavePause, AutosaveFocus} {
		if err := UpdateEditorAppSettings(EditorAppPatch{Autosave: strp(mode)}); err != nil {
			t.Errorf("autosave %q: %v", mode, err)
		}
	}
}

// Review Focus 2: a file that does not parse is shown, not overwritten.
func TestAMalformedSettingsFileRefusesAWrite(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	path := appSettingsFile(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadAppSettings(); err == nil || !strings.Contains(err.Error(), "settings.json") {
		t.Errorf("LoadAppSettings() error = %v; want a parse error naming the file", err)
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{WordWrap: boolp(true)}); err == nil {
		t.Fatal("a write over a malformed file was accepted")
	}
	b, _ := os.ReadFile(path)
	if string(b) != "{not json" {
		t.Errorf("the malformed file was rewritten: %q", b)
	}
	got := LoadEditorSettings()
	if got.AppError == "" || got.FontSize != DefaultEditorFontSize {
		t.Errorf("LoadEditorSettings() = %+v; want defaults plus the error", got)
	}
}

func editorProjectFixture(t *testing.T, org string) string {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "project.json")
	raw := `{"name":"widgets","org":"` + org + `","roots":[{"path":"."}],"environments":{}}`
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestUpdateProjectEditorSettingsAddsTheBlockAndKeepsTheRest(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	if err := UpdateProjectEditorSettings(path, EditorProjectPatch{TabSize: intp(2)}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateProjectEditorSettings(path, EditorProjectPatch{InsertSpaces: boolp(false)}); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := p.Editor.Resolved(); got != (EditorProjectValues{TabSize: 2, InsertSpaces: false}) {
		t.Errorf("Resolved() = %+v", got)
	}
	if len(p.Roots) != 1 {
		t.Errorf("Roots = %+v; a field the patch did not name must survive", p.Roots)
	}
	b, _ := os.ReadFile(path)
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["editor"]; !ok {
		t.Errorf("project.json has no editor block: %s", b)
	}
}

func TestUpdateProjectEditorSettingsRefusesOutOfRange(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	before, _ := os.ReadFile(path)
	for _, n := range []int{0, 17} {
		err := UpdateProjectEditorSettings(path, EditorProjectPatch{TabSize: intp(n)})
		if _, ok := IsUserError(err); err == nil || !ok {
			t.Errorf("tab size %d: err = %v; want a UserError", n, err)
		}
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Errorf("a refused write changed project.json")
	}
}

// Review Focus 5.
func TestAProjectInAnotherOrgIsNotWritten(t *testing.T) {
	path := editorProjectFixture(t, "other")
	before, _ := os.ReadFile(path)
	if err := UpdateProjectEditorSettings(path, EditorProjectPatch{TabSize: intp(2)}); err == nil {
		t.Fatal("a project filed under another organisation was written")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Errorf("project.json changed")
	}
}

func TestAnEmptyPatchWritesNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(appSettingsFile(t)); !os.IsNotExist(err) {
		t.Errorf("an empty patch created settings.json")
	}
}
```

`IsUserError(err) (string, bool)` is `mcperr.go:19`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'Settings|Resolved|RangeEdges|AnotherOrg|EmptyPatch'`
Expected: FAIL to compile — `undefined: LoadAppSettings` and the other new names.

- [ ] **Step 3: Add `Project.Editor`**

In `internal/wakilcore/config.go`, the `Project` struct becomes:

```go
type Project struct {
	Name         string                 `json:"name"`
	Org          string                 `json:"org"`
	Roots        []Root                 `json:"roots"`
	Scopes       Scopes                 `json:"scopes"`
	Environments map[string]Environment `json:"environments"`
	// Editor is the project's editor settings (3b-v, Decision 38): the values that belong to the
	// code, committed with it. Absent means every default.
	Editor *EditorProjectSettings `json:"editor,omitempty"`
}
```

- [ ] **Step 4: Write `editorsettings.go`**

```go
package wakilcore

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
)

// Editor settings (3b-v, Decision 38) live in two tiers, split by who a setting belongs to.
//
//   - App-wide, the operator's own, in ~/.wakil/settings.json under "editor": font size, word
//     wrap, autosave. The file is design-language §14's "Wakil" scope, and its first.
//   - Per project, the code's, in project.json under "editor": tab size and tabs or spaces, so a
//     teammate gets the same values.
//
// A missing file, key or field reads as its default, so no install needs a migration. Every
// write is read-modify-write from disk at dispatch, and a refused write writes nothing — the
// rules UpdateOrg and SaveProject already follow.
const (
	AutosaveOff   = "off"
	AutosavePause = "pause"
	AutosaveFocus = "focus"

	DefaultEditorFontSize = 12
	MinEditorFontSize     = 9
	MaxEditorFontSize     = 24
	DefaultEditorTabSize  = 4
	MinEditorTabSize      = 1
	MaxEditorTabSize      = 16
)

const appSettingsFileName = "settings.json"

// AppSettings is ~/.wakil/settings.json. Keys this build does not know are dropped on a write,
// as SaveProject drops them.
type AppSettings struct {
	Editor EditorAppSettings `json:"editor"`
}

// EditorAppSettings is the app-wide tier as stored: zero values mean "the default".
type EditorAppSettings struct {
	FontSize int    `json:"fontSize,omitempty"`
	WordWrap bool   `json:"wordWrap,omitempty"`
	Autosave string `json:"autosave,omitempty"`
}

// EditorProjectSettings is the per-project tier as stored. InsertSpaces is a pointer because
// false (tabs) is a value and absent is the default (spaces).
type EditorProjectSettings struct {
	TabSize      int   `json:"tabSize,omitempty"`
	InsertSpaces *bool `json:"insertSpaces,omitempty"`
}

// EditorAppValues is the app-wide tier with every default filled in.
type EditorAppValues struct {
	FontSize int    `json:"fontSize"`
	WordWrap bool   `json:"wordWrap"`
	Autosave string `json:"autosave"`
}

// EditorProjectValues is one project's tier with every default filled in.
type EditorProjectValues struct {
	TabSize      int  `json:"tabSize"`
	InsertSpaces bool `json:"insertSpaces"`
}

// EditorSettings is both tiers resolved for the active project — what editor_settings answers.
// Flat rather than embedding the two halves, so the tool's derived output schema is one plain
// object. AppError is settings.json's read or parse error, whole; the values are then the
// defaults.
type EditorSettings struct {
	FontSize     int    `json:"fontSize"`
	WordWrap     bool   `json:"wordWrap"`
	Autosave     string `json:"autosave"`
	TabSize      int    `json:"tabSize"`
	InsertSpaces bool   `json:"insertSpaces"`
	AppError     string `json:"appError,omitempty"`
}

// Resolved fills the defaults. A stored value outside its range — only a hand edit can put one
// there — reads as the default rather than reaching the editor.
func (s EditorAppSettings) Resolved() EditorAppValues {
	v := EditorAppValues{FontSize: DefaultEditorFontSize, WordWrap: s.WordWrap, Autosave: AutosaveOff}
	if s.FontSize >= MinEditorFontSize && s.FontSize <= MaxEditorFontSize {
		v.FontSize = s.FontSize
	}
	if validAutosave(s.Autosave) {
		v.Autosave = s.Autosave
	}
	return v
}

// Resolved fills the defaults; a nil receiver (a project with no editor block) is every default.
func (s *EditorProjectSettings) Resolved() EditorProjectValues {
	v := EditorProjectValues{TabSize: DefaultEditorTabSize, InsertSpaces: true}
	if s == nil {
		return v
	}
	if s.TabSize >= MinEditorTabSize && s.TabSize <= MaxEditorTabSize {
		v.TabSize = s.TabSize
	}
	if s.InsertSpaces != nil {
		v.InsertSpaces = *s.InsertSpaces
	}
	return v
}

func validAutosave(s string) bool {
	return s == AutosaveOff || s == AutosavePause || s == AutosaveFocus
}

func appSettingsPath() (string, error) {
	dir, err := WakilDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, appSettingsFileName), nil
}

// LoadAppSettings reads ~/.wakil/settings.json. No file is not an error: it is every default.
func LoadAppSettings() (AppSettings, error) {
	path, err := appSettingsPath()
	if err != nil {
		return AppSettings{}, err
	}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return AppSettings{}, nil
	}
	if err != nil {
		return AppSettings{}, fmt.Errorf("read %s: %w", path, err)
	}
	var s AppSettings
	if err := json.Unmarshal(b, &s); err != nil {
		return AppSettings{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return s, nil
}

// EditorAppPatch names the app-wide fields a write changes; nil leaves a field as it is on disk.
type EditorAppPatch struct {
	FontSize *int
	WordWrap *bool
	Autosave *string
}

// UpdateEditorAppSettings applies p to settings.json, read from disk now. A file that does not
// parse is refused rather than overwritten: the operator wrote it by hand, and a write would
// discard what it holds.
func UpdateEditorAppSettings(p EditorAppPatch) error {
	if p.FontSize == nil && p.WordWrap == nil && p.Autosave == nil {
		return nil
	}
	current, err := LoadAppSettings()
	if err != nil {
		return UserError(err.Error() + " — fix or remove the file by hand; a write here would discard what it holds")
	}
	if p.FontSize != nil {
		if *p.FontSize < MinEditorFontSize || *p.FontSize > MaxEditorFontSize {
			return UserError(fmt.Sprintf("font size %d is out of range: %d to %d",
				*p.FontSize, MinEditorFontSize, MaxEditorFontSize))
		}
		current.Editor.FontSize = *p.FontSize
	}
	if p.WordWrap != nil {
		current.Editor.WordWrap = *p.WordWrap
	}
	if p.Autosave != nil {
		if !validAutosave(*p.Autosave) {
			return UserError("autosave " + strconv.Quote(*p.Autosave) + " is not one of off, pause, focus")
		}
		current.Editor.Autosave = *p.Autosave
	}
	path, err := appSettingsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

// EditorProjectPatch names the per-project fields a write changes.
type EditorProjectPatch struct {
	TabSize      *int
	InsertSpaces *bool
}

// UpdateProjectEditorSettings applies p to the project file at projectPath, read from disk now.
// A project filed under another organisation is refused, as SetDatabaseDSN refuses one.
func UpdateProjectEditorSettings(projectPath string, p EditorProjectPatch) error {
	if p.TabSize == nil && p.InsertSpaces == nil {
		return nil
	}
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	project, err := LoadProject(projectPath)
	if err != nil {
		return err
	}
	if project.Org != org {
		return UserError("project " + strconv.Quote(project.Name) + " belongs to org " +
			strconv.Quote(project.Org) + ", not " + strconv.Quote(org) +
			" — a project stored in another organisation is read-only here")
	}
	if p.TabSize != nil && (*p.TabSize < MinEditorTabSize || *p.TabSize > MaxEditorTabSize) {
		return UserError(fmt.Sprintf("tab size %d is out of range: %d to %d",
			*p.TabSize, MinEditorTabSize, MaxEditorTabSize))
	}
	if project.Editor == nil {
		project.Editor = &EditorProjectSettings{}
	}
	if p.TabSize != nil {
		project.Editor.TabSize = *p.TabSize
	}
	if p.InsertSpaces != nil {
		v := *p.InsertSpaces
		project.Editor.InsertSpaces = &v
	}
	return SaveProject(projectPath, *project)
}

// LoadEditorSettings resolves both tiers for the active project. It never fails: an unreadable
// settings.json is reported in AppError with the defaults in place, and no active project means
// the project defaults.
func LoadEditorSettings() EditorSettings {
	var out EditorSettings
	app, err := LoadAppSettings()
	if err != nil {
		out.AppError = err.Error()
	}
	a := app.Editor.Resolved()
	out.FontSize, out.WordWrap, out.Autosave = a.FontSize, a.WordWrap, a.Autosave
	var project *EditorProjectSettings
	if r, err := Resolve(); err == nil && r.Project != nil {
		project = r.Project.Editor
	}
	pv := project.Resolved()
	out.TabSize, out.InsertSpaces = pv.TabSize, pv.InsertSpaces
	return out
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ -run 'Settings|Resolved|RangeEdges|AnotherOrg|EmptyPatch'`
Expected: PASS. Then `go test ./internal/wakilcore/` — expected PASS (the `Project` change must
not break `projectwrite_test.go`; an absent `editor` stays absent because of `omitempty`).

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/editorsettings.go internal/wakilcore/editorsettings_test.go internal/wakilcore/config.go
git commit -m "wakilcore: editor settings in two tiers — settings.json and project.json's editor block (3b-v PR 1)"
```

---

### Task 2: config_tree and the three wakil-ctx tools

**Files:**
- Modify: `internal/wakilcore/configtree.go` (`ConfigTree`, `ConfigTreeProject`,
  `LoadConfigTreeFor`, `configTreeProject`, `emptyConfigTree`)
- Modify: `internal/wakilcore/configtree_test.go`
- Modify: `cmd/wakil-ctx/main.go` (args structs near `updateOrgArgs`, tools after `update_org`)
- Modify: `cmd/wakil-ctx/schema_test.go` (the tool list), `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: Task 1's `LoadAppSettings`, `Resolved`, `UpdateEditorAppSettings`,
  `UpdateProjectEditorSettings`, `LoadEditorSettings`, patches.
- Produces:
  - `ConfigTree.Editor EditorAppValues` (JSON `editor`), `ConfigTree.EditorError string` (JSON
    `editorError`, omitempty), `ConfigTreeProject.Editor EditorProjectValues` (JSON `editor`)
  - Tools: `editor_settings` (no args → `EditorSettings`), `set_editor_settings`
    (`fontSize?: int, wordWrap?: bool, autosave?: string`), `set_project_editor_settings`
    (`projectPath: string, tabSize?: int, insertSpaces?: bool`)

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/configtree_test.go` (reuse that file's existing fixture helpers
for an org with one registered project; read the top of the file for their names):

```go
func TestConfigTreeCarriesTheEditorTiers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	pdir := t.TempDir()
	pp := filepath.Join(pdir, "project.json")
	raw := `{"name":"widgets","org":"acme","roots":[{"path":"."}],"environments":{},"editor":{"tabSize":2,"insertSpaces":false}}`
	if err := os.WriteFile(pp, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("acme", map[string]ProjectEntry{"widgets": {Path: pp}}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(15)}); err != nil {
		t.Fatal(err)
	}

	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Editor != (EditorAppValues{FontSize: 15, WordWrap: false, Autosave: AutosaveOff}) {
		t.Errorf("tree.Editor = %+v", tree.Editor)
	}
	if tree.EditorError != "" {
		t.Errorf("tree.EditorError = %q", tree.EditorError)
	}
	if len(tree.Projects) != 1 || tree.Projects[0].Editor != (EditorProjectValues{TabSize: 2, InsertSpaces: false}) {
		t.Errorf("tree.Projects = %+v", tree.Projects)
	}
}

// Review Focus 2: the tree still answers, with the defaults and the error, when settings.json
// does not parse.
func TestConfigTreeNamesAMalformedSettingsFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := appSettingsFile(t)
	if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.EditorError == "" || tree.Editor.FontSize != DefaultEditorFontSize {
		t.Errorf("tree = %+v; want defaults plus editorError", tree)
	}
}
```

Add to `cmd/wakil-ctx/schema_test.go`'s list, after `"capacity",`:

```go
		// editor_settings, set_editor_settings and set_project_editor_settings added by 3b-v
		// part 1 — the editor's two settings tiers (Decision 38).
		"editor_settings",
		"set_editor_settings",
		"set_project_editor_settings",
```

Append to `cmd/wakil-ctx/main_test.go`:

```go
// A write through the tool lands in the resolved read, for both tiers.
func TestEditorSettingsRoundTrip(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "editor-settings-test", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	call := func(name string, args map[string]any) *mcp.CallToolResult {
		t.Helper()
		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil {
			t.Fatalf("CallTool %s: %v", name, err)
		}
		return res
	}
	if res := call("set_editor_settings", map[string]any{"fontSize": 16, "autosave": "pause"}); res.IsError {
		t.Fatalf("set_editor_settings: %s", textOf(t, res))
	}
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "tabSize": 2}); res.IsError {
		t.Fatalf("set_project_editor_settings: %s", textOf(t, res))
	}
	if res := call("set_editor_settings", map[string]any{"fontSize": 99}); !res.IsError {
		t.Fatal("an out-of-range font size was accepted")
	}

	got := wakilcore.LoadEditorSettings()
	want := wakilcore.EditorSettings{FontSize: 16, WordWrap: false, Autosave: "pause", TabSize: 2, InsertSpaces: true}
	if got != want {
		t.Errorf("LoadEditorSettings() = %+v, want %+v", got, want)
	}
	res := call("editor_settings", nil)
	if res.IsError {
		t.Fatalf("editor_settings: %s", textOf(t, res))
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), `"tabSize":2`) || !strings.Contains(string(b), `"fontSize":16`) {
		t.Errorf("editor_settings = %s", b)
	}
}
```

Add `"encoding/json"` and `"strings"` to `main_test.go`'s imports if absent.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/wakilcore/ -run ConfigTree && go test ./cmd/wakil-ctx/ -run 'OutputSchemas|EditorSettingsRoundTrip'`
Expected: FAIL — `tree.Editor undefined`; the schema test reports the three tools missing.

- [ ] **Step 3: Extend the config tree**

In `configtree.go`, add to `ConfigTreeProject` after `Environments`:

```go
	// Editor is the project's editor settings with defaults filled (3b-v). Never absent: a
	// project with no editor block shows the defaults its Editor node edits.
	Editor EditorProjectValues `json:"editor"`
```

Add to `ConfigTree` after `Projects`:

```go
	// Editor is the app-wide editor tier (~/.wakil/settings.json) with defaults filled — not
	// this organisation's, but the pane draws it beside the organisation, so it travels in the
	// pane's one read. EditorError is that file's read or parse error, whole (Rule 8); Editor then
	// holds the defaults.
	Editor      EditorAppValues `json:"editor"`
	EditorError string          `json:"editorError,omitempty"`
```

In `LoadConfigTreeFor`, right after `tree := emptyConfigTree(org)`:

```go
	app, err := LoadAppSettings()
	if err != nil {
		tree.EditorError = err.Error()
	}
	tree.Editor = app.Editor.Resolved()
```

In `configTreeProject`, add `Editor: project.Editor.Resolved(),` to the `out` literal. In
`emptyConfigTree`, add `Editor: EditorAppSettings{}.Resolved(),` to the literal.

- [ ] **Step 4: Add the tools**

In `cmd/wakil-ctx/main.go`, after `updateOrgArgs`:

```go
// setEditorSettingsArgs is the app-wide editor tier's edit (3b-v). Pointers for updateOrgArgs'
// reason: absent leaves what is on disk.
type setEditorSettingsArgs struct {
	FontSize *int    `json:"fontSize,omitempty" jsonschema:"9 to 24; omit to leave unchanged"`
	WordWrap *bool   `json:"wordWrap,omitempty" jsonschema:"omit to leave unchanged"`
	Autosave *string `json:"autosave,omitempty" jsonschema:"off, pause or focus; omit to leave unchanged"`
}

// setProjectEditorSettingsArgs is one project's editor tier's edit (3b-v).
type setProjectEditorSettingsArgs struct {
	ProjectPath  string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	TabSize      *int   `json:"tabSize,omitempty" jsonschema:"1 to 16; omit to leave unchanged"`
	InsertSpaces *bool  `json:"insertSpaces,omitempty" jsonschema:"true indents with spaces, false with tabs; omit to leave unchanged"`
}
```

After the `update_org` tool registration:

```go
	// Added by 3b-v (Decision 38): the editor's settings, in two tiers. The read is the agent's
	// as much as the operator's; the two writes are operator-only on the Swift side
	// (Decision 30), and read-modify-write from disk here.
	mcp.AddTool(s, &mcp.Tool{Name: "editor_settings", Description: "Read the editor settings in force: font size, word wrap and autosave (off, pause or focus) from the operator's app-wide settings, and tab size and tabs-or-spaces from the active project. Defaults fill anything unset. appError carries settings.json's error, whole, when it cannot be read; the defaults are then in force."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.EditorSettings, error) {
			return nil, wakilcore.LoadEditorSettings(), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_editor_settings", Description: "Change the app-wide editor settings: font size (9 to 24), word wrap, autosave (off, pause or focus). Read-modify-write: omit a field to leave it unchanged. Refuses an out-of-range value, and refuses to write over a settings.json that does not parse."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setEditorSettingsArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.UpdateEditorAppSettings(wakilcore.EditorAppPatch{
				FontSize: a.FontSize, WordWrap: a.WordWrap, Autosave: a.Autosave,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_project_editor_settings", Description: "Change one project's editor settings: tab size (1 to 16) and whether to indent with spaces. Written to the project's project.json, read-modify-write; omit a field to leave it unchanged. A file's own indentation still wins in the editor; these are the fallback. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setProjectEditorSettingsArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.UpdateProjectEditorSettings(a.ProjectPath, wakilcore.EditorProjectPatch{
				TabSize: a.TabSize, InsertSpaces: a.InsertSpaces,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ && go test ./cmd/wakil-ctx/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/configtree.go internal/wakilcore/configtree_test.go cmd/wakil-ctx/main.go cmd/wakil-ctx/schema_test.go cmd/wakil-ctx/main_test.go
git commit -m "wakil-ctx: editor_settings, set_editor_settings and set_project_editor_settings; config_tree carries both tiers (3b-v PR 1)"
```

---

### Task 3: WakilKit — the settings types and the three actions

**Files:**
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift`
- Create: `app/Sources/WakilKit/Editor/EditorSettings.swift`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (after `ctx_update_org`)
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (`operatorOnlyActions`,
  `operatorOnlyDenialMessage`)
- Modify: `app/Tests/WakilKitTests/StandardActionsTests.swift` (registered-name list and the
  missing-client params map), `app/Tests/WakilKitTests/ActionClassificationTests.swift` (the
  pinned operator-only list)
- Create: `app/Tests/WakilKitTests/EditorSettingsTests.swift`

**Interfaces:**
- Consumes: Task 2's tool names and JSON shapes.
- Produces:
  - `public enum EditorAutosaveMode: String, Sendable, CaseIterable { case off, pause, focus }`
  - `public struct SettingsEditor: Sendable, Equatable, Decodable { fontSize: Int; wordWrap: Bool; autosave: EditorAutosaveMode }` with `static let defaults`
  - `public struct SettingsProjectEditor: Sendable, Equatable, Decodable { tabSize: Int; insertSpaces: Bool }` with `static let defaults`
  - `SettingsTree.editor: SettingsEditor`, `SettingsTree.editorError: String?`,
    `SettingsProject.editor: SettingsProjectEditor`
  - `public struct EditorSettings: Sendable, Equatable, Decodable { app: SettingsEditor; project: SettingsProjectEditor; appError: String? }` with `static let defaults` and `var viewOptions: EditorViewOptions`
  - `public struct EditorViewOptions: Sendable, Equatable { fontSize: Int; wordWrap: Bool; tabSize: Int; insertSpaces: Bool }`
  - `public func decodeEditorSettings(fromResult: JSONValue?) -> EditorSettings?`
  - Actions `ctx_editor_settings` (`.read`, agent-reachable), `ctx_set_editor_settings` and
    `ctx_set_project_editor_settings` (`.control`, operator-only)

`EditorAutosaveMode` is declared in `Panes/SettingsTree.swift` beside `SettingsEditor`, because
`Panes` may not depend on `Editor` (only `Editor -> Panes` is in
`Fixtures/layering-allowed.txt`).

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/EditorSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private actor RecordingCaller: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object([:])])
    }
    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

private func registryWithRecordingContext() async throws -> (ActionRegistry, RecordingCaller) {
    let caller = RecordingCaller()
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "editor-settings")
    await registerStandardActions(
        into: registry, context: caller, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())
    return (registry, caller)
}

@Suite struct EditorSettingsTests {
    @Test func theTreeDecodesBothEditorTiers() throws {
        let json = """
        {"structuredContent":{"org":{"id":"acme","displayName":"","jiraBase":"","defaultProvider":""},
         "providers":[],"projects":[{"name":"w","path":"/p.json","roots":[],"environments":[],
           "editor":{"tabSize":2,"insertSpaces":false}}],
         "editor":{"fontSize":15,"wordWrap":true,"autosave":"focus"}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let tree = try #require(decodeSettingsTree(fromResult: value))
        #expect(tree.editor == SettingsEditor(fontSize: 15, wordWrap: true, autosave: .focus))
        #expect(tree.editorError == nil)
        #expect(tree.projects.first?.editor == SettingsProjectEditor(tabSize: 2, insertSpaces: false))
    }

    /// An older wakil-ctx answers no editor keys: the tree still decodes, with the defaults.
    @Test func aTreeWithNoEditorKeysDecodesToTheDefaults() throws {
        let json = """
        {"structuredContent":{"org":{"id":"acme","displayName":"","jiraBase":"","defaultProvider":""},
         "providers":[],"projects":[{"name":"w","path":"/p.json"}]}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let tree = try #require(decodeSettingsTree(fromResult: value))
        #expect(tree.editor == .defaults)
        #expect(tree.projects.first?.editor == .defaults)
    }

    @Test func editorSettingsDecodeFlatAndMapToViewOptions() throws {
        let json = """
        {"structuredContent":{"fontSize":14,"wordWrap":true,"autosave":"pause","tabSize":2,"insertSpaces":false}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let s = try #require(decodeEditorSettings(fromResult: value))
        #expect(s.app.autosave == .pause)
        #expect(s.viewOptions == EditorViewOptions(fontSize: 14, wordWrap: true, tabSize: 2, insertSpaces: false))
        #expect(s.appError == nil)
    }

    /// An unknown autosave value reads as off — the editor never guesses a write.
    @Test func anUnknownAutosaveModeReadsAsOff() throws {
        let json = #"{"structuredContent":{"fontSize":12,"wordWrap":false,"autosave":"always","tabSize":4,"insertSpaces":true}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(decodeEditorSettings(fromResult: value)?.app.autosave == .off)
    }

    @Test func theAppWriteForwardsOnlyTypedKeysItKnows() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        _ = try await registry.dispatch(
            name: "ctx_set_editor_settings",
            params: .object(["fontSize": .integer(14), "wordWrap": .string("yes"), "bogus": .bool(true)]),
            origin: .ui, environment: "staging", confirmation: nil)
        let calls = await caller.recorded()
        guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
            Issue.record("expected one call, got \(calls)"); return
        }
        #expect(calls[0].tool == "set_editor_settings")
        #expect(arguments == ["fontSize": .integer(14)])
    }

    @Test func theProjectWriteNeedsAProjectPath() async throws {
        let (registry, caller) = try await registryWithRecordingContext()
        await #expect(throws: (any Error).self) {
            try await registry.dispatch(
                name: "ctx_set_project_editor_settings", params: .object(["tabSize": .integer(2)]),
                origin: .ui, environment: "staging", confirmation: nil)
        }
        #expect(await caller.recorded().isEmpty)
        _ = try await registry.dispatch(
            name: "ctx_set_project_editor_settings",
            params: .object(["projectPath": .string("/p.json"), "tabSize": .integer(2), "insertSpaces": .bool(false)]),
            origin: .ui, environment: "staging", confirmation: nil)
        let calls = await caller.recorded()
        #expect(calls.last?.tool == "set_project_editor_settings")
        #expect(calls.last?.arguments == .object([
            "projectPath": .string("/p.json"), "tabSize": .integer(2), "insertSpaces": .bool(false),
        ]))
    }

    /// Decision 30: the agent reads and never writes, and the refusal names why.
    @Test func theWritesAreOperatorOnlyAndTheReadIsNot() async throws {
        let (registry, _) = try await registryWithRecordingContext()
        let all = await registry.all()
        let read = try #require(all.first { $0.name == "ctx_editor_settings" })
        #expect(read.kind == .read && read.audience == .agentReachable)
        for name in ["ctx_set_editor_settings", "ctx_set_project_editor_settings"] {
            let action = try #require(all.first { $0.name == name })
            #expect(action.kind == .control && action.audience == .operatorOnly)
            #expect(operatorOnlyActions.contains(name))
            let decision = permissionDecision(toolName: "mcp__wakil__\(name)", knownActions: [name, "ctx_editor_settings"])
            guard case .deny(let reason) = decision else {
                Issue.record("\(name) must be denied, got \(decision)"); return
            }
            #expect(reason.contains("Decision 30"))
            #expect(reason.contains("ctx_editor_settings"))
        }
    }
}
```

Also update the two pinned lists so they fail now and pass after Step 3:
- `StandardActionsTests.swift` registered-names list (line ~2403): insert
  `"ctx_editor_settings",` after `"ctx_create_org",`, and `"ctx_set_editor_settings",` and
  `"ctx_set_project_editor_settings",` after `"ctx_set_environment",` (keep the list sorted).
- The same file's missing-client params map (line ~2669): add
  `"ctx_set_editor_settings": .object(["fontSize": .integer(14)]),`,
  `"ctx_set_project_editor_settings": .object(["projectPath": .string("/p.json"), "tabSize": .integer(2)]),`
  and `"ctx_editor_settings": .object([:]),`.
- `ActionClassificationTests.swift` pinned operator-only list (line ~133): add
  `"ctx_set_editor_settings", "ctx_set_project_editor_settings",` in sorted position, with the
  comment `// 3b-v (Decision 38): Decision 30 kept — the agent reads editor settings, never writes them.`

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorSettingsTests|StandardActionsTests|ActionClassificationTests'`
Expected: FAIL to compile — `SettingsEditor`, `decodeEditorSettings` undefined.

- [ ] **Step 3: Implement**

In `Panes/SettingsTree.swift`, add after `SettingsOrg`:

```swift
/// How autosave behaves (3b-v): never, a second after the last edit, or when focus leaves.
/// Declared here rather than in `Editor/`, because `Panes` may not depend on `Editor`.
public enum EditorAutosaveMode: String, Sendable, Equatable, CaseIterable {
    case off, pause, focus

    public var label: String {
        switch self {
        case .off: "Off"
        case .pause: "After a pause"
        case .focus: "When focus leaves"
        }
    }
}

/// The app-wide editor tier (`~/.wakil/settings.json`), defaults filled by Go. An absent key or an
/// unknown autosave value decodes to the default, so an older or hand-edited answer still draws.
public struct SettingsEditor: Sendable, Equatable, Decodable {
    public var fontSize: Int
    public var wordWrap: Bool
    public var autosave: EditorAutosaveMode

    public static let defaults = SettingsEditor(fontSize: 12, wordWrap: false, autosave: .off)

    public init(fontSize: Int, wordWrap: Bool, autosave: EditorAutosaveMode) {
        self.fontSize = fontSize
        self.wordWrap = wordWrap
        self.autosave = autosave
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? Self.defaults.fontSize
        wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? Self.defaults.wordWrap
        autosave = (try c.decodeIfPresent(String.self, forKey: .autosave)).flatMap(EditorAutosaveMode.init(rawValue:)) ?? .off
    }

    private enum CodingKeys: String, CodingKey { case fontSize, wordWrap, autosave }
}

/// One project's editor tier (`project.json`'s `editor`), defaults filled by Go.
public struct SettingsProjectEditor: Sendable, Equatable, Decodable {
    public var tabSize: Int
    public var insertSpaces: Bool

    public static let defaults = SettingsProjectEditor(tabSize: 4, insertSpaces: true)

    public init(tabSize: Int, insertSpaces: Bool) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabSize = try c.decodeIfPresent(Int.self, forKey: .tabSize) ?? Self.defaults.tabSize
        insertSpaces = try c.decodeIfPresent(Bool.self, forKey: .insertSpaces) ?? Self.defaults.insertSpaces
    }

    private enum CodingKeys: String, CodingKey { case tabSize, insertSpaces }
}
```

`SettingsTree`: add stored properties `public var editor: SettingsEditor` and
`public var editorError: String?`; init parameters `editor: SettingsEditor = .defaults,
editorError: String? = nil` (assigned in the body); in `init(from:)`:
`editor = try container.decodeIfPresent(SettingsEditor.self, forKey: .editor) ?? .defaults` and
`editorError = try container.decodeIfPresent(String.self, forKey: .editorError)`; add
`editor, editorError` to `CodingKeys`.

`SettingsProject`: add `public var editor: SettingsProjectEditor`; init parameter
`editor: SettingsProjectEditor = .defaults`; decode with
`decodeIfPresent(SettingsProjectEditor.self, forKey: .editor) ?? .defaults`; add `editor` to
`CodingKeys`.

`Editor/EditorSettings.swift`:

```swift
import Foundation

/// What Monaco is told (3b-v): the editor options the settings decide.
public struct EditorViewOptions: Sendable, Equatable {
    public var fontSize: Int
    public var wordWrap: Bool
    public var tabSize: Int
    public var insertSpaces: Bool
    public init(fontSize: Int, wordWrap: Bool, tabSize: Int, insertSpaces: Bool) {
        self.fontSize = fontSize
        self.wordWrap = wordWrap
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

/// The editor settings in force: the app-wide tier and the active project's, as
/// `ctx_editor_settings` answers them (one flat object). `appError` is settings.json's error,
/// whole; the values are then the defaults.
public struct EditorSettings: Sendable, Equatable, Decodable {
    public var app: SettingsEditor
    public var project: SettingsProjectEditor
    public var appError: String?

    public static let defaults = EditorSettings(app: .defaults, project: .defaults, appError: nil)

    public init(app: SettingsEditor, project: SettingsProjectEditor, appError: String?) {
        self.app = app
        self.project = project
        self.appError = appError
    }

    /// Both halves read the same flat object.
    public init(from decoder: Decoder) throws {
        app = try SettingsEditor(from: decoder)
        project = try SettingsProjectEditor(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appError = try c.decodeIfPresent(String.self, forKey: .appError)
    }

    private enum CodingKeys: String, CodingKey { case appError }

    public var viewOptions: EditorViewOptions {
        EditorViewOptions(fontSize: app.fontSize, wordWrap: app.wordWrap,
                          tabSize: project.tabSize, insertSpaces: project.insertSpaces)
    }
}

/// `ctx_editor_settings`' reply, or nil when it is not one.
public func decodeEditorSettings(fromResult result: JSONValue?) -> EditorSettings? {
    guard case .object(let object)? = result, let structured = object["structuredContent"],
          let data = try? JSONEncoder().encode(structured) else { return nil }
    return try? JSONDecoder().decode(EditorSettings.self, from: data)
}
```

In `StandardActions.swift`, after the `ctx_update_org` registration:

```swift
    // 3b-v (Decision 38). The editor's settings: font size, wrap and autosave app-wide, tab size
    // and tabs-or-spaces per project. The read is the agent's too; the writes are operator-only
    // on Decision 30, kept — an agent that could change them could change how the operator's
    // files are saved without the operator seeing.
    await registry.register(Action(
        name: "ctx_editor_settings",
        description: "Read the editor settings in force: font size, word wrap and autosave (off, "
            + "pause or focus) from the operator's app-wide settings, and tab size and "
            + "tabs-or-spaces from the active project. appError carries settings.json's error "
            + "when it cannot be read; the defaults are then in force.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_editor_settings", role: "context")
            }
            return try await callChecked(
                context, tool: "editor_settings", arguments: .object([:]),
                action: "ctx_editor_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_editor_settings",
        description: "Change the app-wide editor settings: fontSize (9 to 24), wordWrap, autosave "
            + "(off, pause or focus). Read-modify-write: omit a field to leave it. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "fontSize": .object(["type": .string("integer")]),
                "wordWrap": .object(["type": .string("boolean")]),
                "autosave": .object(["type": .string("string"), "enum": .array([.string("off"), .string("pause"), .string("focus")])]),
            ]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_editor_settings", role: "context")
            }
            // Key by key and type by type, for ctx_update_org's reason: only what the caller sent,
            // and only in the shape Go decodes, reaches Go.
            guard case .object(let fields) = params else {
                throw StandardActionError.missingParam(action: "ctx_set_editor_settings", param: "fontSize")
            }
            var arguments: [String: JSONValue] = [:]
            if case .integer? = fields["fontSize"] { arguments["fontSize"] = fields["fontSize"] }
            if case .bool? = fields["wordWrap"] { arguments["wordWrap"] = fields["wordWrap"] }
            if case .string? = fields["autosave"] { arguments["autosave"] = fields["autosave"] }
            return try await callChecked(
                context, tool: "set_editor_settings", arguments: .object(arguments),
                action: "ctx_set_editor_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_set_project_editor_settings",
        description: "Change one project's editor settings in its project.json: tabSize (1 to 16) "
            + "and insertSpaces (false indents with tabs). A file's own indentation still wins; "
            + "these are the fallback. Read-modify-write. Operator-only.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "projectPath": .object(["type": .string("string")]),
                "tabSize": .object(["type": .string("integer")]),
                "insertSpaces": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("projectPath")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_project_editor_settings", role: "context")
            }
            guard case .object(let fields) = params, case .string(let path)? = fields["projectPath"], !path.isEmpty else {
                throw StandardActionError.missingParam(action: "ctx_set_project_editor_settings", param: "projectPath")
            }
            var arguments: [String: JSONValue] = ["projectPath": .string(path)]
            if case .integer? = fields["tabSize"] { arguments["tabSize"] = fields["tabSize"] }
            if case .bool? = fields["insertSpaces"] { arguments["insertSpaces"] = fields["insertSpaces"] }
            return try await callChecked(
                context, tool: "set_project_editor_settings", arguments: .object(arguments),
                action: "ctx_set_project_editor_settings", timeout: MCPClient.readReplyTimeout)
        }
    ))
```

In `PermissionPrompt.swift`, add to `operatorOnlyActions` (after `"ctx_list_accounts",`):

```swift
    // 3b-v (Decision 38). Decision 30 kept for the editor's settings: they carry no credential,
    // but autosave decides when the operator's files are written, and the operator, not the
    // agent, chooses that.
    "ctx_set_editor_settings", "ctx_set_project_editor_settings",
```

and a case to `operatorOnlyDenialMessage`, before `case "ctx_update_org":`:

```swift
    case "ctx_set_editor_settings", "ctx_set_project_editor_settings":
        return "\(toolName): only the operator changes editor settings (Decision 30). Autosave "
            + "decides when their files are written, and the font, wrap and tabs are how they "
            + "read and type — choices that are theirs. You may READ them: ctx_editor_settings "
            + "answers the settings in force. Ask the operator to change them in the settings "
            + "pane (\u{2318},)."
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'EditorSettingsTests|StandardActionsTests|ActionClassificationTests|OrganisationEditTests|LayeringTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/SettingsTree.swift app/Sources/WakilKit/Editor/EditorSettings.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/MCP/PermissionPrompt.swift app/Tests/WakilKitTests/EditorSettingsTests.swift app/Tests/WakilKitTests/StandardActionsTests.swift app/Tests/WakilKitTests/ActionClassificationTests.swift
git commit -m "Settings: the editor tiers in the tree, ctx_editor_settings, and two operator-only writes (3b-v PR 2)"
```

---

### Task 4: WindowModel — the settings in force, refresh and save

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (beside `refreshSettings` /
  `saveOrganisationField` at ~2443–2515; `refreshContext` at ~1684; `invalidateForOrgChange` at
  ~1785)
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`
- Modify: `app/Tests/WakilKitTests/EditorSettingsTests.swift`

**Interfaces:**
- Consumes: Task 3's actions, `EditorSettings`, `decodeEditorSettings`.
- Produces on `WindowModel`:
  - `public internal(set) var editorSettings: EditorSettings` (`.defaults` until read)
  - `public func refreshEditorSettings() async`
  - `public func saveEditorSettings(_ fields: [String: JSONValue]) async -> String?`
  - `public func saveProjectEditorSettings(projectPath: String, _ fields: [String: JSONValue]) async -> String?`

- [ ] **Step 1: Write the failing tests**

Append to `EditorSettingsTests.swift` (a second suite, `@MainActor`, reusing
`editorWindowParts` from `WindowModelEditorTests.swift`, which registers no `ctx_*` actions):

```swift
@Suite @MainActor struct WindowEditorSettingsTests {
    /// With no wakil-ctx answering, the window keeps the defaults rather than failing.
    @Test func aReadThatFailsKeepsTheDefaults() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        await model.refreshEditorSettings()
        #expect(model.editorSettings == .defaults)
    }

    @Test func anOrgSwitchResetsTheEditorSettings() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        model.editorSettings = EditorSettings(
            app: SettingsEditor(fontSize: 20, wordWrap: true, autosave: .pause),
            project: .defaults, appError: nil)
        await model.invalidateForOrgChange()
        #expect(model.editorSettings == .defaults)
    }

    /// A refused write answers its sentence, for the pane to show beside the field.
    @Test func aRefusedWriteAnswersItsSentence() async throws {
        let (model, _, _) = await editorWindowParts(roots: ["/p/api"])
        let refusal = await model.saveEditorSettings(["fontSize": .integer(14)])
        #expect(refusal?.isEmpty == false)
    }
}
```

In `InvalidationContractTests.swift`, add `"editorSettings",` to `orgDerived` with the comment
`// 3b-v: the settings in force include the active project's tabs, so they follow the org.`

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowEditorSettingsTests|InvalidationContractTests'`
Expected: FAIL to compile — `editorSettings` undefined.

- [ ] **Step 3: Implement**

Add near `settings` / `settingsFailure` in `WindowModel`:

```swift
    /// The editor settings in force (3b-v): app-wide plus the active project's, read through
    /// `ctx_editor_settings` on every context read and after every editor-settings write. Every
    /// editor pane is drawn with `editorSettings.viewOptions`, and autosave reads its mode here.
    public internal(set) var editorSettings: EditorSettings = .defaults
```

After `saveOrganisationField`:

```swift
    /// Re-reads the editor settings in force. A failed read keeps what the window had — the
    /// defaults until the first read lands — because an editor drawn with the defaults is
    /// usable, and a refusal here would block nothing worth blocking (Rule 8).
    public func refreshEditorSettings() async {
        guard let result = try? await registry.dispatch(
                  name: "ctx_editor_settings", params: .object([:]), origin: .ui,
                  environment: environment, confirmation: nil),
              let decoded = decodeEditorSettings(fromResult: result)
        else { return }
        editorSettings = decoded
    }

    /// Saves app-wide editor fields, then re-reads the tree and the settings in force. Answers
    /// the refusal's own sentence, or nil — `saveOrganisationField`'s shape.
    public func saveEditorSettings(_ fields: [String: JSONValue]) async -> String? {
        await saveEditorSettings(action: "ctx_set_editor_settings", params: .object(fields))
    }

    /// Saves one project's editor fields into its project.json.
    public func saveProjectEditorSettings(projectPath: String, _ fields: [String: JSONValue]) async -> String? {
        var params = fields
        params["projectPath"] = .string(projectPath)
        return await saveEditorSettings(action: "ctx_set_project_editor_settings", params: .object(params))
    }

    private func saveEditorSettings(action: String, params: JSONValue) async -> String? {
        var refusal: String?
        do {
            _ = try await registry.dispatch(
                name: action, params: params, origin: .ui, environment: environment, confirmation: nil)
        } catch {
            refusal = statusDescribingFailure(action, error)
        }
        await refreshSettings()
        await refreshEditorSettings()
        return refusal
    }
```

In `refreshContext`, on the success path right after `await vocabulary?.contextChanged(active)`:

```swift
            // 3b-v: the tabs follow the project, so the settings in force are read with it.
            await refreshEditorSettings()
```

In `invalidateForOrgChange`, beside the other editor resets:

```swift
        editorSettings = .defaults
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowEditorSettingsTests|InvalidationContractTests|WindowModelEditorTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/EditorSettingsTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "Window: the editor settings in force, read with the context and after each write (3b-v PR 2)"
```

---

### Task 5: EditorAutosave — which tabs to arm or save

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorAutosave.swift`
- Create: `app/Tests/WakilKitTests/EditorAutosaveTests.swift`

**Interfaces:**
- Consumes: `EditorSnapshot`, `EditorTab` (`EditorSnapshot.swift`), `editorTabKey`
  (`EditorRenderer.swift`), `EditorAutosaveMode` (Task 3).
- Produces:
  - `public func editorAutosaveEligible(_ tab: EditorTab) -> Bool`
  - `public struct EditorAutosaveStep: Sendable, Equatable { var arm: [String]; var saveNow: [String] }` (paths)
  - `public struct EditorAutosave: Sendable` with `init()`,
    `mutating func observe(pane: String, snapshot: EditorSnapshot, mode: EditorAutosaveMode) -> EditorAutosaveStep`,
    `mutating func forget(pane: String)`, `mutating func reset()`,
    `static func focusLeft(_ snapshot: EditorSnapshot, mode: EditorAutosaveMode) -> [String]`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private func file(_ path: String, text: String = "x", saved: String = "x", edits: Int = 0) -> EditorTab {
    var t = EditorTab.file(path: path, root: "/p", text: saved, mtime: 1, language: "go")
    t.text = text
    t.edits = edits
    return t
}

@Suite struct EditorAutosaveTests {
    @Test func onlyADirtyInSyncWritableFileTabIsEligible() {
        #expect(editorAutosaveEligible(file("/p/a", text: "y")))
        #expect(!editorAutosaveEligible(file("/p/a")))                       // clean
        var scratch = EditorTab.scratch(number: 1, language: "go"); scratch.text = "y"
        #expect(!editorAutosaveEligible(scratch))
        var changed = file("/p/a", text: "y"); changed.diskState = .changedOnDisk
        #expect(!editorAutosaveEligible(changed))
        var deleted = file("/p/a", text: "y"); deleted.diskState = .deleted
        #expect(!editorAutosaveEligible(deleted))
        var saving = file("/p/a", text: "y"); saving.saving = true
        #expect(!editorAutosaveEligible(saving))
        var readOnly = file("/p/a", text: "y"); readOnly.readOnly = true
        #expect(!editorAutosaveEligible(readOnly))
    }

    @Test func pauseArmsOnEachEditAndNotOnTheFirstLook() {
        var a = EditorAutosave()
        let clean = EditorSnapshot(tabs: [file("/p/a")], active: 0)
        #expect(a.observe(pane: "e1", snapshot: clean, mode: .pause) == EditorAutosaveStep(arm: [], saveNow: []))
        let typed = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1)], active: 0)
        #expect(a.observe(pane: "e1", snapshot: typed, mode: .pause).arm == ["/p/a"])
        // The same snapshot again (a refresh with no edit) does not re-arm.
        #expect(a.observe(pane: "e1", snapshot: typed, mode: .pause).arm.isEmpty)
        let again = EditorSnapshot(tabs: [file("/p/a", text: "yy", edits: 2)], active: 0)
        #expect(a.observe(pane: "e1", snapshot: again, mode: .pause).arm == ["/p/a"])
    }

    @Test func offAndFocusNeverArm() {
        for mode in [EditorAutosaveMode.off, .focus] {
            var a = EditorAutosave()
            _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [file("/p/a")], active: 0), mode: mode)
            let typed = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1)], active: 0)
            #expect(a.observe(pane: "e1", snapshot: typed, mode: mode).arm.isEmpty)
        }
    }

    @Test func focusSavesTheTabSwitchedAwayFrom() {
        var a = EditorAutosave()
        let onA = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1), file("/p/b")], active: 0)
        _ = a.observe(pane: "e1", snapshot: onA, mode: .focus)
        let onB = EditorSnapshot(tabs: onA.tabs, active: 1)
        #expect(a.observe(pane: "e1", snapshot: onB, mode: .focus).saveNow == ["/p/a"])
        // Switching away from a clean tab saves nothing.
        let backToA = EditorSnapshot(tabs: onA.tabs, active: 0)
        #expect(a.observe(pane: "e1", snapshot: backToA, mode: .focus).saveNow.isEmpty)
    }

    @Test func pauseDoesNotSaveOnATabSwitch() {
        var a = EditorAutosave()
        let onA = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 1), file("/p/b")], active: 0)
        _ = a.observe(pane: "e1", snapshot: onA, mode: .pause)
        #expect(a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: onA.tabs, active: 1), mode: .pause).saveNow.isEmpty)
    }

    @Test func focusLeftAnswersEveryEligibleTabOnlyInFocusMode() {
        let s = EditorSnapshot(tabs: [file("/p/a", text: "y"), file("/p/b"), file("/p/c", text: "z")], active: 0)
        #expect(EditorAutosave.focusLeft(s, mode: .focus) == ["/p/a", "/p/c"])
        #expect(EditorAutosave.focusLeft(s, mode: .pause).isEmpty)
        #expect(EditorAutosave.focusLeft(s, mode: .off).isEmpty)
    }

    @Test func panesAreTrackedApart() {
        var a = EditorAutosave()
        _ = a.observe(pane: "e1", snapshot: EditorSnapshot(tabs: [file("/p/a")], active: 0), mode: .pause)
        // e2's first look at a dirty tab is its first look: nothing to compare, no arm.
        let e2 = EditorSnapshot(tabs: [file("/p/a", text: "y", edits: 3)], active: 0)
        #expect(a.observe(pane: "e2", snapshot: e2, mode: .pause).arm.isEmpty)
        a.forget(pane: "e1")
        #expect(a.observe(pane: "e1", snapshot: e2, mode: .pause).arm.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter EditorAutosaveTests`
Expected: FAIL to compile — `EditorAutosave` undefined.

- [ ] **Step 3: Implement `EditorAutosave.swift`**

```swift
import Foundation

/// Whether autosave may write `tab` (3b-v): a file, dirty, in sync with disk, writable, and not
/// already saving. A tab marked changed on disk or deleted is the operator's to resolve —
/// autosave would overwrite the disk or recreate the file without them choosing to (3b-i's
/// Reload, Compare and ⌘S stay theirs).
public func editorAutosaveEligible(_ tab: EditorTab) -> Bool {
    !tab.isScratch && tab.dirty && tab.diskState == .inSync && !tab.readOnly && !tab.saving
}

/// What one look at a pane asks autosave to do, by path.
public struct EditorAutosaveStep: Sendable, Equatable {
    /// Tabs edited since the last look, in `pause` mode: their timers (re)start.
    public var arm: [String]
    /// Tabs to save now: in `focus` mode, the dirty tab the pane switched away from.
    public var saveNow: [String]
    public init(arm: [String], saveNow: [String]) {
        self.arm = arm
        self.saveNow = saveNow
    }
}

/// Autosave's memory (3b-v): per pane, each file tab's edit counter and the active tab, so a new
/// look at a snapshot can say what changed. It decides; the window keeps the timers and saves.
/// An edit is any change to a tab's `edits` counter — the operator's typing and the agent's
/// edits alike, since both bump it.
public struct EditorAutosave: Sendable {
    private var edits: [String: [String: Int]] = [:]
    private var active: [String: String] = [:]

    public init() {}

    public mutating func observe(pane: String, snapshot: EditorSnapshot, mode: EditorAutosaveMode) -> EditorAutosaveStep {
        var step = EditorAutosaveStep(arm: [], saveNow: [])
        let seen = edits[pane]
        var now: [String: Int] = [:]
        for tab in snapshot.tabs {
            guard let path = tab.path else { continue }
            now[path] = tab.edits
            // A tab seen for the first time has nothing to compare with, so it never arms.
            if mode == .pause, editorAutosaveEligible(tab), let before = seen?[path], before != tab.edits {
                step.arm.append(path)
            }
        }
        let current = snapshot.active.flatMap { snapshot.tabs.indices.contains($0) ? editorTabKey(snapshot.tabs[$0]) : nil }
        if mode == .focus, let previous = active[pane], previous != current,
           let left = snapshot.tabs.first(where: { editorTabKey($0) == previous }),
           editorAutosaveEligible(left), let path = left.path {
            step.saveNow.append(path)
        }
        edits[pane] = now
        active[pane] = current
        return step
    }

    public mutating func forget(pane: String) {
        edits[pane] = nil
        active[pane] = nil
    }

    public mutating func reset() {
        edits = [:]
        active = [:]
    }

    /// The tabs to save when a pane loses focus, or Wakil stops being the active app.
    public static func focusLeft(_ snapshot: EditorSnapshot, mode: EditorAutosaveMode) -> [String] {
        guard mode == .focus else { return [] }
        return snapshot.tabs.filter(editorAutosaveEligible).compactMap(\.path)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter EditorAutosaveTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorAutosave.swift app/Tests/WakilKitTests/EditorAutosaveTests.swift
git commit -m "Editor: autosave decides which tabs to arm and which to save (3b-v PR 3)"
```

---

### Task 6: WindowModel — autosave wired to edits, focus and resign-active

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`setCell` ~1606, `refreshLayout` ~3737,
  the editor section ~4179–4560, `invalidateForOrgChange`)
- Modify: `app/Tests/WakilKitTests/WindowModelEditorTests.swift`
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift`

**Interfaces:**
- Consumes: Task 4's `editorSettings`; Task 5's `EditorAutosave`, `editorAutosaveEligible`;
  `editorSaves` (`WindowModel.swift:4179`), `dispatch`, `refreshEditor`, `panes.editorSnapshot`.
- Produces on `WindowModel`:
  - `@ObservationIgnored var editorAutosaveDelay: Duration` (1 s; tests shorten it)
  - `@ObservationIgnored private(set) var editorAutosaveCount: Int` (test seam: autosaves dispatched)
  - `public func editorAppDidResignActive() async`
  - `func settleEditorAutosave() async` (test-only: waits for pending timers and saves)

- [ ] **Step 1: Write the failing tests**

Add to `WindowModelEditorTests` (inside the suite):

```swift
    /// Opens a.go, sets the autosave mode and delay, and types "b". The delay is set BEFORE the
    /// edit, because the edit arms the timer with whatever delay is in force then.
    private func openTyped(_ model: WindowModel, _ files: FakeFiles, mode: EditorAutosaveMode,
                           delay: Duration = .milliseconds(30)) async throws -> String {
        model.editorAutosaveDelay = delay
        model.editorSettings = EditorSettings(
            app: SettingsEditor(fontSize: 12, wordWrap: false, autosave: mode), project: .defaults, appError: nil)
        await model.refreshContext()
        await files.put("/p/api/a.go", "a")
        await model.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/a.go")]))
        await model.refreshLayout()
        let pane = try #require(model.layoutSnapshot.panes.first { $0.kind == "editor" }?.id)
        await model.focusPane(id: pane)
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "b", basis: 0)
        return pane
    }

    @Test func afterAPauseTheEditIsWrittenToDisk() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause)
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "b")
        #expect(model.editor(pane)?.tabs.first?.dirty == false)
    }

    @Test func withAutosaveOffNothingIsWritten() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .off)
        try await Task.sleep(for: .milliseconds(120))
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.editorAutosaveCount == 0)
    }

    @Test func typingAgainRestartsThePause() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(120))
        await model.editorBufferDidChange(pane: pane, tab: 0, text: "bc", basis: 0)
        try await Task.sleep(for: .milliseconds(120))
        // 240 ms after the first edit, 120 after the second: not yet.
        #expect(await files.text(of: "/p/api/a.go") == "a")
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "bc")
        #expect(model.editorAutosaveCount == 1)
    }

    // Review Focus 3.
    @Test func aTabClosedBeforeThePauseEndsIsNotWritten() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .milliseconds(150))
        await model.dispatchFromSurface("editor_close", .object(["pane": .string(pane), "discard": .bool(true)]))
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "a")
        #expect(model.status.isEmpty)
    }

    // Review Focus 4.
    @Test func autosaveDoesNotFireWhileASaveIsInFlight() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .milliseconds(150))
        await files.setSlowWrite(true)
        let save = Task { await model.saveFocusedEditor() }
        while true {
            await model.refreshPanes()
            if model.editor(pane)?.tabs.first?.saving == true { break }
            await Task.yield()
        }
        await model.settleEditorAutosave()
        #expect(model.editorAutosaveCount == 0)
        await files.releaseWrite()
        await save.value
        #expect(await files.text(of: "/p/api/a.go") == "b")
    }

    @Test func aTabChangedOnDiskIsNotAutosaved() async throws {
        let (model, files) = await editorWindowWithFiles()
        let pane = try await openTyped(model, files, mode: .pause, delay: .milliseconds(150))
        // Another writer changes the file; the refresh marks the dirty tab changed on disk (3b-i).
        await files.put("/p/api/a.go", "z")
        await model.dispatchFromSurface("editor_refresh", .object(["pane": .string(pane), "root": .string("/p/api")]))
        await model.refreshPanes()
        #expect(model.editor(pane)?.tabs.first?.diskState == .changedOnDisk)
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "z")
    }

    @Test func whenFocusLeavesThePaneItsDirtyTabsSave() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .focus)
        await model.openPane(kind: "git")      // focus moves to the new pane
        await model.settleEditorAutosave()
        #expect(await files.text(of: "/p/api/a.go") == "b")
    }

    @Test func resigningActiveSavesInFocusModeOnly() async throws {
        let (model, files) = await editorWindowWithFiles()
        _ = try await openTyped(model, files, mode: .focus)
        await model.editorAppDidResignActive()
        #expect(await files.text(of: "/p/api/a.go") == "b")

        let (other, otherFiles) = await editorWindowWithFiles()
        _ = try await openTyped(other, otherFiles, mode: .pause, delay: .seconds(60))
        await other.editorAppDidResignActive()
        #expect(await otherFiles.text(of: "/p/api/a.go") == "a")
    }
```

`aTabChangedOnDiskIsNotAutosaved` arms a 150 ms timer and marks the tab changed on disk before
it fires, through `editor_refresh` (`EditorActions.swift:522`) — `WindowModel.panes` is private.
If the refresh does not mark a dirty tab `changedOnDisk` within the timer, raise the delay rather
than reaching into the store; Task 5's eligibility test already pins the rule itself.

In `InvalidationContractTests.swift`, extend the 3b-i editor line in `orgDerived` to:
`"editorSaveAsRequest", "editorSaves", "editorTabsWrites", "editorAutosave", "editorAutosaveTimers", "editorAutosaveRuns",`
with the comment `// 3b-v: autosave's memory and pending timers name the outgoing org's panes.`
Add `"editorAutosaveDelay", "editorAutosaveCount",` to `orgIndependent` beside the existing
`editorTabsDelay` / `editorTabsWriteCount` entries (find them with
`grep -n "editorTabsDelay" app/Tests/WakilKitTests/InvalidationContractTests.swift`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelEditorTests|InvalidationContractTests'`
Expected: FAIL to compile — `editorAutosaveDelay`, `settleEditorAutosave` undefined.

- [ ] **Step 3: Implement**

Beside `editorTabsDelay` in the editor section:

```swift
    // MARK: Autosave (3b-v)

    /// How long after the last edit `pause` mode saves. Tests shorten it.
    @ObservationIgnored var editorAutosaveDelay: Duration = .seconds(1)
    /// Autosave's memory of each pane's tabs (`EditorAutosave`).
    @ObservationIgnored private var editorAutosave = EditorAutosave()
    /// The pending pause timer per "pane\npath".
    @ObservationIgnored private var editorAutosaveTimers: [String: Task<Void, Never>] = [:]
    /// Autosaves dispatched (a test seam).
    @ObservationIgnored private(set) var editorAutosaveCount = 0
    /// Autosaves running now, so a test can wait for them.
    @ObservationIgnored private var editorAutosaveRuns: [Task<Void, Never>] = []

    /// One look at an editor pane's snapshot: arm the timers for edited tabs, save the tab a
    /// pane switched away from. Called from `setCell`, which every editor refresh passes through.
    private func autosaveObserve(pane: String, snapshot: EditorSnapshot) {
        let step = editorAutosave.observe(pane: pane, snapshot: snapshot, mode: editorSettings.app.autosave)
        for path in step.arm { armAutosave(pane: pane, path: path) }
        for path in step.saveNow { runAutosave(pane: pane, path: path) }
    }

    private func armAutosave(pane: String, path: String) {
        let key = pane + "\n" + path
        editorAutosaveTimers[key]?.cancel()
        let delay = editorAutosaveDelay
        editorAutosaveTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.editorAutosaveTimers[key] = nil
            await self.autosave(pane: pane, path: path)
        }
    }

    private func runAutosave(pane: String, path: String) {
        editorAutosaveRuns.append(Task { [weak self] in await self?.autosave(pane: pane, path: path) })
    }

    /// Saves one tab through `editor_save` — the same path as ⌘S (Decision 36). Eligibility is
    /// re-checked now: since the timer was armed the tab may have been saved, closed, or marked
    /// changed on disk. A ⌘S in flight for the pane wins (Rule 5). A failed write leaves the tab
    /// dirty with the failure on it, as a failed ⌘S does; the next edit or focus change tries again.
    private func autosave(pane: String, path: String) async {
        guard editorSaves[pane] == nil else { return }
        let snapshot = await panes.editorSnapshot(paneId: pane)
        guard let tab = snapshot.tabs.first(where: { $0.path == path }), editorAutosaveEligible(tab) else { return }
        editorAutosaveCount += 1
        _ = await dispatch("editor_save", .object(["pane": .string(pane), "path": .string(path)]))
        await refreshEditor(pane: pane)
    }

    /// `focus` mode, when focus leaves `pane`: every eligible tab in it saves.
    private func autosaveFocusLeft(pane: String) {
        guard let snapshot = editor(pane) else { return }
        for path in EditorAutosave.focusLeft(snapshot, mode: editorSettings.app.autosave) {
            runAutosave(pane: pane, path: path)
        }
    }

    /// Wakil stopped being the active app (WakilApp forwards the notification): in `focus` mode,
    /// every eligible tab in every editor pane on the canvas saves.
    public func editorAppDidResignActive() async {
        for pane in layoutSnapshot.panes where pane.kind == "editor" {
            guard let snapshot = editor(pane.id) else { continue }
            for path in EditorAutosave.focusLeft(snapshot, mode: editorSettings.app.autosave) {
                await autosave(pane: pane.id, path: path)
            }
        }
    }

    /// TEST-ONLY: waits until no autosave timer or run is pending.
    func settleEditorAutosave() async {
        while !editorAutosaveTimers.isEmpty || !editorAutosaveRuns.isEmpty {
            let timers = Array(editorAutosaveTimers.values), runs = editorAutosaveRuns
            editorAutosaveRuns = []
            for t in timers { await t.value }
            for r in runs { await r.value }
            await Task.yield()
        }
    }
```

`setCell` becomes:

```swift
    private func setCell(_ paneId: String, _ snapshot: PaneSnapshot) {
        if let cell = paneCells[paneId] { cell.snapshot = snapshot } else { paneCells[paneId] = PaneSnapshotCell(snapshot) }
        if let editor = snapshot.editor { autosaveObserve(pane: paneId, snapshot: editor) }
    }
```

In `refreshLayout`, directly after `layoutSnapshot = reading.snapshot`:

```swift
        // 3b-v: focus leaving an editor pane is `focus` mode's trigger.
        if let left = before.focusedId, left != layoutSnapshot.focusedId { autosaveFocusLeft(pane: left) }
```

In `invalidateForOrgChange`, beside the `editorTabsWrites` cancellation:

```swift
        editorAutosaveTimers.values.forEach { $0.cancel() }
        editorAutosaveTimers = [:]
        editorAutosaveRuns = []
        editorAutosave.reset()
```

Where a pane's cell is dropped on close (search `paneCells[` assignments to `nil` /
`removeValue`), also call `editorAutosave.forget(pane:)` for that id.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelEditorTests|InvalidationContractTests|EditorAutosaveTests'`
Expected: PASS. Run each new test three times
(`--filter afterAPauseTheEditIsWrittenToDisk` etc.) — timer tests must not flake.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/WindowModelEditorTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "Window: autosave after a pause or when focus leaves, through editor_save (3b-v PR 3)"
```

---

### Task 7: WakilApp — Monaco takes the options

**Files:**
- Modify: `app/Sources/WakilApp/monaco-host.html` (editor branch ~68–130; diff branch ~168)
- Modify: `app/Sources/WakilApp/MonacoEditorRenderer.swift`, `MonacoDiffRenderer.swift`
- Modify: `app/Sources/WakilApp/EditorPane.swift` (`EditorPane` inputs; `EditorHost` ~438–560)
- Modify: `app/Sources/WakilApp/GitPane.swift` (its diff host ~504)
- Modify: `app/Sources/WakilApp/Canvas.swift` (where `EditorPane(` and `GitPane(` are built)

**Interfaces:**
- Consumes: `WindowModel.editorSettings.viewOptions` (Task 4), `EditorViewOptions` (Task 3).
- Produces: `MonacoEditorRenderer.setOptions(_ options: EditorViewOptions)`,
  `MonacoDiffRenderer.setFontSize(_ size: Int)`; JS `wakilSetOptions(o)`, `wakilSetFontSize(n)`.

WakilApp has no test target: this task is verified by `make app-build` and by the e2e auditor
(Cover rung) and the walk.

- [ ] **Step 1: The page**

In the editor branch of `monaco-host.html`, after `const basis = {};` add:

```js
      // 3b-v: the settings' options. Tabs are a fallback: each model detects its own indentation
      // and uses these only where it cannot (a file's own indentation wins).
      let opts = { fontSize: 12, wordWrap: false, tabSize: 4, insertSpaces: true };
      function indent(m) { m.detectIndentation(opts.insertSpaces, opts.tabSize); }
      window.wakilSetOptions = function (o) {
        opts = o;
        ed.updateOptions({ fontSize: o.fontSize, wordWrap: o.wordWrap ? 'on' : 'off' });
        Object.keys(models).forEach(function (k) { indent(models[k]); });
      };
```

In `wakilShowModel`, change the model creation line to:

```js
        if (!models[key]) { models[key] = monaco.editor.createModel(text, language); indent(models[key]); }
```

In the diff branch, after `const editor = monaco.editor.createDiffEditor(...)`:

```js
    window.wakilSetFontSize = function (n) { editor.updateOptions({ fontSize: n }); };
```

- [ ] **Step 2: The renderers**

`MonacoEditorRenderer`, beside `setBasis`:

```swift
    /// The settings' options (3b-v). Queued until the page is ready, like every other call.
    func setOptions(_ o: EditorViewOptions) {
        run("wakilSetOptions({fontSize:\(o.fontSize),wordWrap:\(o.wordWrap),tabSize:\(o.tabSize),insertSpaces:\(o.insertSpaces)})")
    }
```

`MonacoDiffRenderer`: add the same queued-call helper use (it already has a ready queue; read
its `run`/`onReady` pattern and follow it):

```swift
    /// The editor font size (3b-v), so a diff reads at the size the operator chose.
    func setFontSize(_ size: Int) { run("wakilSetFontSize(\(size))") }
```

If `MonacoDiffRenderer` names its queued-call helper differently, use that helper; do not call
`evaluateJavaScript` before `ready`.

- [ ] **Step 3: Pass the options down**

`EditorPane`: add `let viewOptions: EditorViewOptions` after `let snapshot: EditorSnapshot`.
In `EditorHost`, add:

```swift
    /// The options last asked for, applied when the renderer exists and again whenever they change.
    private var wantedOptions: EditorViewOptions?
    private var appliedOptions: EditorViewOptions?

    func setOptions(_ o: EditorViewOptions) {
        wantedOptions = o
        applyOptions()
    }

    private func applyOptions() {
        guard let renderer, let o = wantedOptions, o != appliedOptions else { return }
        renderer.setOptions(o)
        appliedOptions = o
    }
```

Call `applyOptions()` right after the renderer is created (after `let made = MonacoEditorRenderer(...)`
is stored into `renderer`). In `EditorPane.body`, on the outermost container:

```swift
        .onChange(of: viewOptions, initial: true) { _, o in
            host.setOptions(o)
            compareHost.renderer?.setFontSize(o.fontSize)
        }
```

In `showCompare()`, after `renderer.show(...)`, add `renderer.setFontSize(viewOptions.fontSize)`.

`GitPane`: add `var fontSize: Int = 12` as an input; after its `MonacoDiffRenderer` is made, call
`made.setFontSize(fontSize)`, and add `.onChange(of: fontSize) { _, n in host.renderer?.setFontSize(n) }`
(use the git pane's own host property name).

`Canvas.swift`: pass `viewOptions: model.editorSettings.viewOptions` to `EditorPane(` and
`fontSize: model.editorSettings.app.fontSize` to `GitPane(`.

- [ ] **Step 4: Build**

Run: `make app-build`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/monaco-host.html app/Sources/WakilApp/MonacoEditorRenderer.swift app/Sources/WakilApp/MonacoDiffRenderer.swift app/Sources/WakilApp/EditorPane.swift app/Sources/WakilApp/GitPane.swift app/Sources/WakilApp/Canvas.swift
git commit -m "Editor: Monaco takes the font size, wrap and tab fallback from the settings; diffs take the font size (3b-v PR 4)"
```

---

### Task 8: WakilApp — the two Editor nodes, and resign-active

**Files:**
- Create: `app/Sources/WakilApp/EditorSettingsForms.swift`
- Modify: `app/Sources/WakilApp/SettingsPane.swift` (inputs ~45–130, `treeColumn` ~228,
  `subject(of:)` ~413, `SettingsNode` ~1872–1919)
- Modify: `app/Sources/WakilApp/Canvas.swift` (the `SettingsPane(` call ~462)
- Modify: `app/Sources/WakilApp/AppScene.swift` (resign-active)

**Interfaces:**
- Consumes: `SettingsTree.editor`, `.editorError`, `SettingsProject.editor`, `.path` (Task 3);
  `WindowModel.saveEditorSettings`, `saveProjectEditorSettings`, `editorAppDidResignActive`
  (Tasks 4, 6); `SettingsScale`, `SettingsPalette`, `SegmentedChoice` (`SettingsForm.swift`).
- Produces: `SettingsNode.editor`, `SettingsNode.projectEditor(String)`; accessibility ids
  `settings.tree.editor`, `settings.tree.projectEditor.<project>`, `settings.editor.fontSize`,
  `settings.editor.wordWrap`, `settings.editor.autosave.<mode>`, `settings.projectEditor.tabSize`,
  `settings.projectEditor.indent.<spaces|tabs>`, `settings.editor.error`.

- [ ] **Step 1: The forms**

`app/Sources/WakilApp/EditorSettingsForms.swift`:

```swift
import WakilKit
import SwiftUI

/// A whole number edited in a field (3b-v): ± steps write at once; typed text writes when focus
/// leaves or on Return (Rule 2). An invalid value keeps the text, shows why, and writes nothing
/// (Rule 8) — the range check is Go's, so the sentence is Go's.
struct NumberSettingRow: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let identifier: String
    let save: (Int) async -> String?

    @State private var draft: String?
    @State private var refusal: String?
    @FocusState private var focused: Bool

    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
            HStack(spacing: 8) {
                TextField("", text: Binding(get: { draft ?? "\(value)" }, set: { draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsScale.body, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.88))
                    .frame(width: 44)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
                    .accessibilityIdentifier(identifier)
                Stepper("", value: Binding(get: { value }, set: { n in write(n) }), in: range)
                    .labelsHidden()
                    .accessibilityIdentifier("\(identifier).stepper")
                Text("\(range.lowerBound)–\(range.upperBound)")
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(coolWhite.opacity(0.30))
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).refusal")
            }
        }
        .padding(.bottom, 4)
    }

    private func commit() {
        guard let text = draft?.trimmingCharacters(in: .whitespaces), text != "\(value)" else { draft = nil; return }
        guard let n = Int(text) else {
            refusal = "\(label) must be a whole number from \(range.lowerBound) to \(range.upperBound)"
            return
        }
        write(n)
    }

    private func write(_ n: Int) {
        Task {
            let answer = await save(n)
            refusal = answer
            if answer == nil { draft = nil }
        }
    }
}

/// A two-state setting drawn as `SegmentedChoice`, written on click.
struct ChoiceSettingRow: View {
    let label: String
    let options: [String]
    let selected: String
    let identifier: (String) -> String
    let save: (String) async -> String?

    @State private var refusal: String?
    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
            SegmentedChoice(
                options: options,
                selection: Binding(get: { selected }, set: { option in
                    guard option != selected else { return }
                    Task { refusal = await save(option) }
                }),
                identifier: identifier)
            if let refusal {
                Text(refusal).font(.system(size: SettingsScale.body)).foregroundStyle(SettingsPalette.caution)
            }
        }
        .padding(.bottom, 4)
    }
}

/// The top-level Editor node: the operator's app-wide editor settings (3b-v).
struct EditorAppSettingsForm: View {
    let editor: SettingsEditor
    let error: String?
    let save: ([String: JSONValue]) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Text(error + " — the defaults are in force; fix or remove the file to change them here.")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.editor.error")
            }
            NumberSettingRow(
                label: "Font size", value: editor.fontSize, range: 9...24,
                identifier: "settings.editor.fontSize",
                save: { n in await save(["fontSize": .integer(Int64(n))]) })
            ChoiceSettingRow(
                label: "Word wrap", options: ["Off", "On"], selected: editor.wordWrap ? "On" : "Off",
                identifier: { option in "settings.editor.wordWrap.\(option.lowercased())" },
                save: { option in await save(["wordWrap": .bool(option == "On")]) })
            ChoiceSettingRow(
                label: "Autosave", options: EditorAutosaveMode.allCases.map(\.label),
                selected: editor.autosave.label,
                identifier: { label in
                    let mode = EditorAutosaveMode.allCases.first { $0.label == label }?.rawValue ?? label
                    return "settings.editor.autosave.\(mode)"
                },
                save: { label in
                    let mode = EditorAutosaveMode.allCases.first { $0.label == label } ?? .off
                    return await save(["autosave": .string(mode.rawValue)])
                })
            Text("Yours across every organisation and project — stored in ~/.wakil/settings.json.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.30))
        }
    }
}

/// A project's Editor node: the settings that belong to its code, in its project.json (3b-v).
struct EditorProjectSettingsForm: View {
    let editor: SettingsProjectEditor
    let save: ([String: JSONValue]) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NumberSettingRow(
                label: "Tab size", value: editor.tabSize, range: 1...16,
                identifier: "settings.projectEditor.tabSize",
                save: { n in await save(["tabSize": .integer(Int64(n))]) })
            ChoiceSettingRow(
                label: "Indent with", options: ["Spaces", "Tabs"], selected: editor.insertSpaces ? "Spaces" : "Tabs",
                identifier: { option in "settings.projectEditor.indent.\(option.lowercased())" },
                save: { option in await save(["insertSpaces": .bool(option == "Spaces")]) })
            Text("A file's own indentation wins; these apply to new files and files with none. "
                 + "Stored in this project's project.json, so they travel with the code.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.30))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

Check the `SettingsScale` member names (`micro`, `microTracking`, `body`, `meta`) against
`SettingsForm.swift`, and `SegmentedChoice`'s init (`options:selection:identifier:held:`); use
the names that file defines.

- [ ] **Step 2: The pane**

In `SettingsPane`, add two inputs after `saveOrganisationField`:

```swift
    /// Saves app-wide editor fields (3b-v) and answers the refusal's sentence, or nil.
    var saveEditorSettings: ([String: JSONValue]) async -> String? = { _ in nil }
    /// Saves one project's editor fields: the project file's path, then the fields.
    var saveProjectEditorSettings: (String, [String: JSONValue]) async -> String? = { _, _ in nil }
```

`SettingsNode`: add cases `case editor` and `case projectEditor(String)`; in
`identifierFragment` add `case .editor: return "editor"` and
`case .projectEditor(let name): return "projectEditor.\(name)"`; in `breadcrumb(in:)` add
`case .editor: return ["Wakil", "Editor"]` and
`case .projectEditor(let name): return [organisation, "Projects", name, "Editor"]`.

In `treeColumn`, make the first row:

```swift
                row(.editor, label: "Editor", depth: 0)
```

before `row(.organisation, …)`, and inside `ForEach(tree?.projects ?? [] …)`, right after
`row(.project(project.name), …)`:

```swift
                    row(.projectEditor(project.name), label: "Editor", depth: 2)
```

In `subject(of:)`, add:

```swift
        case .editor:
            EditorAppSettingsForm(editor: tree.editor, error: tree.editorError, save: saveEditorSettings)
        case .projectEditor(let name):
            if let project = tree.projects.first(where: { $0.name == name }) {
                EditorProjectSettingsForm(
                    editor: project.editor,
                    save: { fields in await saveProjectEditorSettings(project.path, fields) })
            } else {
                gone(name)
            }
```

(`gone(_:)` is the helper the environment case already uses for a node whose subject vanished.)

`Canvas.swift`, in the `SettingsPane(` call after `saveOrganisationField:`:

```swift
                    saveEditorSettings: { fields in await model.saveEditorSettings(fields) },
                    saveProjectEditorSettings: { path, fields in
                        await model.saveProjectEditorSettings(projectPath: path, fields)
                    },
```

If Swift reports the argument order is wrong (defaulted `var`s must follow in declaration order),
place them where the compiler asks.

- [ ] **Step 3: Resign-active**

In `AppScene.swift`, on the window's root view (where other `NotificationCenter` publishers
are observed; search `onReceive(`), add:

```swift
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                Task { await model.editorAppDidResignActive() }
            }
```

- [ ] **Step 4: Build**

Run: `make app-build`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/EditorSettingsForms.swift app/Sources/WakilApp/SettingsPane.swift app/Sources/WakilApp/Canvas.swift app/Sources/WakilApp/AppScene.swift
git commit -m "Settings: the Editor node and each project's Editor node; resigning active autosaves (3b-v PR 5)"
```

---

### Task 9: Charter and architecture docs

**Files:**
- Modify: `docs/wakil/decisions.md` (append Decision 38)
- Modify: `docs/wakil/design-language.md` (§14, ~555–566)
- Modify: `docs/architecture/go.md` (~131), `docs/architecture/state.md` (~10–15),
  `docs/architecture/wakilkit.md` (~179, ~483)

- [ ] **Step 1: Decision 38**

Append to `docs/wakil/decisions.md`, following the numbered style of the last decision in the
file (read it first and match its headings and *Reverse if* line):

```markdown
## Decision 38 — Editor settings in two tiers; autosave; Decision 30 kept (2026-10-13)

3b-v gives the editor its settings. **Two tiers, split by who a setting belongs to:** the
operator's — font size, word wrap, autosave, and (part 2) showing ignored files — in a new
`~/.wakil/settings.json`, the first file of design-language §14's *Wakil* scope; and the
code's — tab size, tabs or spaces, and (part 2) the heavy folders — in each project's
`project.json`, so a teammate gets them. A file's own indentation still wins.

**Autosave** has three modes, Off by default: after a 1-second pause, or when focus leaves (a
pane, a tab, or Wakil). It dispatches `editor_save` — Decision 36's write — and never writes a
scratch tab, a tab changed on disk or deleted, or a tab whose save is in flight.

**Decision 30 is kept.** These settings carry no credential, which its *Reverse if* names, but
autosave decides when the operator's files are written and the heavy folders decide what search
covers; the agent reads them (`ctx_editor_settings`) and never writes them.

Go owns both tiers (`wakilcore/editorsettings.go`, three `wakil-ctx` tools). A UserDefaults store
was rejected: two stores, two read paths, and an app-wide half the agent could not read.

**Reverse if:** an editor setting needs a per-organisation value, or the agent needs to change a
setting to do its job.
```

If `docs/wakil/decisions.md` on this branch has no Decision 37 yet (3b-ii adds it on its own
branch), still number this 38 and add one line under it: `Decision 37 is 3b-ii's (root focus
dropped), landing with that branch.`

- [ ] **Step 2: design-language §14**

Under the *Wakil* (app-wide) scope bullet, add: `Stored in ~/.wakil/settings.json (3b-v, Decision
38). First settings: the editor's font size, word wrap and autosave.`

- [ ] **Step 3: Architecture maps**

- `go.md`: add `editorsettings.go` (`AppSettings`, the two editor tiers, `~/.wakil/settings.json`)
  beside `orgupdate.go`.
- `state.md`: add a row — *App-wide editor settings (font size, word wrap, autosave)* |
  `~/.wakil/settings.json` | Go `editorsettings.go` (`wakil-ctx` `set_editor_settings`); and extend
  the project.json row's contents with "editor tabs".
- `wakilkit.md`: add `EditorSettings.swift` and `EditorAutosave.swift` to the Editor folder's list
  and to the table row at ~483.

- [ ] **Step 4: Check and commit**

Run: `make docs-check`
Expected: passes (charter word limit).

```bash
git add docs/wakil/decisions.md docs/wakil/design-language.md docs/architecture/go.md docs/architecture/state.md docs/architecture/wakilkit.md
git commit -m "Docs: Decision 38 — editor settings in two tiers, autosave, Decision 30 kept (3b-v PR 6)"
```

---

## After the last task (controller only)

1. `make build && make test` — Go, all packages.
2. `make app-test` — the whole Swift suite.
3. Then the **Cover** rung: the e2e auditor (`docs/agents/e2e.md`) writes checks for the new
   controls — every `settings.editor.*` and `settings.projectEditor.*` identifier and the two tree
   rows — or `e2e/checks/uncoverable.tsv` lines with reasons, and a live check that a font-size
   change reaches an open editor and that *after a pause* writes the file.
4. Then the **Walk**: a runbook covering both nodes, a live font and wrap change, each autosave
   mode, and a project's tabs applied to a scratch tab.
5. Part 2's plan (ignored files, heavy folders) is written after 3b-ii merges.
