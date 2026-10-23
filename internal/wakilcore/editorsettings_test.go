package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func intp(v int) *int       { return &v }
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
	want := EditorAppValues{FontSize: 12, WordWrap: false, Autosave: AutosaveOff, ShowIgnored: true, GhostText: true, InlineBlame: true}
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
	if v := p.Resolved(); !reflect.DeepEqual(v, EditorProjectValues{TabSize: 4, InsertSpaces: true, HeavyFolders: []string{"vendor", "node_modules"}}) {
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
	if got := s.Editor.Resolved(); got != (EditorAppValues{FontSize: 14, WordWrap: true, Autosave: AutosaveOff, ShowIgnored: true, GhostText: true, InlineBlame: true}) {
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
	if got := p.Editor.Resolved(); !reflect.DeepEqual(got, EditorProjectValues{TabSize: 2, InsertSpaces: false, HeavyFolders: []string{"vendor", "node_modules"}}) {
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

func TestGhostTextDefaultsOnAndIsWrittenAndRead(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if !s.Editor.Resolved().GhostText {
		t.Fatal("ghostText must default on")
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{GhostText: boolp(false)}); err != nil {
		t.Fatal(err)
	}
	s, _ = LoadAppSettings()
	if s.Editor.Resolved().GhostText {
		t.Error("ghostText stayed on after writing off")
	}
}

// 3a-v-a: inline blame defaults on, and is written and read like Show ignored files.
func TestInlineBlameDefaultsOnAndPatches(t *testing.T) {
	if !(EditorAppSettings{}).Resolved().InlineBlame {
		t.Error("InlineBlame defaults off; want on")
	}
	t.Setenv("HOME", t.TempDir())
	if err := UpdateEditorAppSettings(EditorAppPatch{InlineBlame: boolp(false)}); err != nil {
		t.Fatal(err)
	}
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if s.Editor.Resolved().InlineBlame || LoadEditorSettings().InlineBlame {
		t.Error("InlineBlame stayed on after writing off")
	}
}
