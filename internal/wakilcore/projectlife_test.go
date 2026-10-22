package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// lifeSetup gives a temp HOME and a registered org "acme".
func lifeSetup(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	t.Setenv("WAKIL_PROJECT", "")
	t.Setenv("WAKIL_ENVIRONMENT", "")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
}

func lifeRegistry(t *testing.T) map[string]ProjectEntry {
	t.Helper()
	reg, err := LoadRegistryFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	return reg
}

func writeProjectFile(t *testing.T, folder, raw string) string {
	t.Helper()
	path := filepath.Join(folder, ".wakil", "project.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCreateProjectWritesFileAndRow(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	key, entry, err := CreateProject(folder, " orders ")
	if err != nil {
		t.Fatal(err)
	}
	if key != "orders" {
		t.Errorf("key = %q, want the trimmed name", key)
	}
	path := filepath.Join(folder, ".wakil", "project.json")
	if entry.Path != path {
		t.Errorf("entry path = %q, want %q", entry.Path, path)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if p.Name != "orders" || p.Org != "acme" || len(p.Roots) != 1 || p.Roots[0].Path != folder {
		t.Errorf("unexpected file: %+v", p)
	}
	if got := lifeRegistry(t)["orders"]; got.Path != path {
		t.Errorf("registry row = %+v", got)
	}
}

func TestCreateProjectAdoptsExistingFile(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	path := writeProjectFile(t, folder, `{"name":"legacy","org":"acme","roots":[{"path":"/x"}],`+
		`"environments":{"staging":{"databases":[]},"production":{"production":true}}}`)
	before, _ := os.ReadFile(path)
	// The name passed is the folder's (what the UI sends); the file's own name wins.
	key, _, err := CreateProject(folder, "orders")
	if err != nil {
		t.Fatal(err)
	}
	if key != "legacy" {
		t.Errorf("key = %q, want the file's own name", key)
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Errorf("the adopted file was rewritten:\n%s\n---\n%s", before, after)
	}
	p, _ := LoadProject(path)
	if len(p.Environments) != 2 {
		t.Errorf("environments lost: %+v", p.Environments)
	}
	reg := lifeRegistry(t)
	if _, ok := reg["legacy"]; !ok {
		t.Error("no registry row under the file's name")
	}
	if _, ok := reg["orders"]; ok {
		t.Error("registered under the name passed, not the file's")
	}
}

// A project renamed, removed and added back from its folder comes back under the name it was
// renamed to — the key its saved layouts are filed under (spec Call 2).
func TestCreateProjectReaddsARenamedProjectUnderItsFileName(t *testing.T) {
	lifeSetup(t)
	folder := filepath.Join(t.TempDir(), "wakil")
	if _, _, err := CreateProject(folder, "wakil"); err != nil {
		t.Fatal(err)
	}
	if err := RenameProject("wakil", "W"); err != nil {
		t.Fatal(err)
	}
	if err := RemoveProject("W"); err != nil {
		t.Fatal(err)
	}
	key, _, err := CreateProject(folder, "wakil")
	if err != nil {
		t.Fatal(err)
	}
	reg := lifeRegistry(t)
	if key != "W" || reg["W"].Path == "" {
		t.Errorf("key = %q, registry = %+v", key, reg)
	}
	if _, ok := reg["wakil"]; ok {
		t.Error("re-added under the folder's name")
	}
}

// The clash check is on the name the row would take: the file's, when adopting.
func TestCreateProjectRefusesAnAdoptedNameThatClashes(t *testing.T) {
	lifeSetup(t)
	if _, _, err := CreateProject(t.TempDir(), "legacy"); err != nil {
		t.Fatal(err)
	}
	folder := t.TempDir()
	writeProjectFile(t, folder, `{"name":"legacy","org":"acme","roots":[],"environments":{}}`)
	_, _, err := CreateProject(folder, "fresh")
	if err == nil || !strings.Contains(err.Error(), `"legacy"`) {
		t.Fatalf("err = %v", err)
	}
	if _, ok := lifeRegistry(t)["fresh"]; ok {
		t.Error("registered under the name passed")
	}
}

// An adopted file whose own name cannot be a key is refused, naming the file.
func TestCreateProjectRefusesAnAdoptedFileWithNoUsableName(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	path := writeProjectFile(t, folder, `{"name":" ","org":"acme","roots":[],"environments":{}}`)
	_, _, err := CreateProject(folder, "fresh")
	if err == nil || !strings.Contains(err.Error(), path) {
		t.Fatalf("err = %v", err)
	}
	if len(lifeRegistry(t)) != 0 {
		t.Error("a row was added")
	}
}

func TestCreateProjectRefusesOtherOrg(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	writeProjectFile(t, folder, `{"name":"x","org":"other","roots":[],"environments":{}}`)
	_, _, err := CreateProject(folder, "orders")
	if err == nil || !strings.Contains(err.Error(), "other") || !strings.Contains(err.Error(), "Invariant 4") {
		t.Fatalf("err = %v", err)
	}
	if len(lifeRegistry(t)) != 0 {
		t.Error("a row was added")
	}
}

func TestCreateProjectRefusesRegisteredFolder(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	if _, _, err := CreateProject(folder, "first"); err != nil {
		t.Fatal(err)
	}
	_, _, err := CreateProject(folder, "second")
	if err == nil || !strings.Contains(err.Error(), `"first"`) {
		t.Fatalf("err = %v", err)
	}
	if _, ok := lifeRegistry(t)["second"]; ok {
		t.Error("second was registered")
	}
}

func TestCreateProjectRefusesNameClash(t *testing.T) {
	lifeSetup(t)
	if _, _, err := CreateProject(t.TempDir(), "orders"); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	_, _, err := CreateProject(other, "orders")
	if err == nil || !strings.Contains(err.Error(), `"orders"`) {
		t.Fatalf("err = %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(other, ".wakil")); statErr == nil {
		t.Error("a refused create left a file behind")
	}
}

func TestValidNameRefusesEmptyAndSlash(t *testing.T) {
	for _, bad := range []string{"", "   ", "a/b"} {
		if _, err := ValidName(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if got, err := ValidName("  ok "); err != nil || got != "ok" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestRenameProjectRewritesFileAndKey(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	path := writeProjectFile(t, folder, `{"name":"orders","org":"acme","roots":[{"path":"/a"},{"path":"/b"}],`+
		`"environments":{"staging":{}},"editor":{"tabWidth":2}}`)
	if _, _, err := CreateProject(folder, "orders"); err != nil {
		t.Fatal(err)
	}
	if err := RenameProject("orders", "shop"); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if p.Name != "shop" || len(p.Roots) != 2 || len(p.Environments) != 1 || p.Editor == nil {
		t.Errorf("file after rename: %+v", p)
	}
	reg := lifeRegistry(t)
	if _, ok := reg["orders"]; ok {
		t.Error("old key remains")
	}
	if reg["shop"].Path != path {
		t.Errorf("new key: %+v", reg["shop"])
	}
}

func TestRenameProjectRefusesClash(t *testing.T) {
	lifeSetup(t)
	a, b := t.TempDir(), t.TempDir()
	CreateProject(a, "a")
	CreateProject(b, "b")
	err := RenameProject("a", "b")
	if err == nil || !strings.Contains(err.Error(), `"b"`) {
		t.Fatalf("err = %v", err)
	}
	if lifeRegistry(t)["a"].Path == "" {
		t.Error("a vanished")
	}
}

func TestRenameProjectRestoresRegistryOnFileFailure(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	if _, _, err := CreateProject(folder, "orders"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(folder, ".wakil", "project.json")
	fileBefore, _ := os.ReadFile(path)
	regBefore := lifeRegistry(t)

	// The atomic writer replaces the file by rename, so the file's own mode
	// does not stop it; a read-only directory does.
	dir := filepath.Dir(path)
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })

	if err := RenameProject("orders", "shop"); err == nil {
		t.Fatal("expected an error")
	}
	fileAfter, _ := os.ReadFile(path)
	if string(fileBefore) != string(fileAfter) {
		t.Error("project file changed")
	}
	regAfter := lifeRegistry(t)
	if len(regAfter) != 1 || regAfter["orders"] != regBefore["orders"] {
		t.Errorf("registry changed: %+v", regAfter)
	}
}

func TestRenameActiveProjectStillResolves(t *testing.T) {
	lifeSetup(t)
	_, entry, err := CreateProject(t.TempDir(), "orders")
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: entry.Path, Environment: "staging"}); err != nil {
		t.Fatal(err)
	}
	if err := RenameProject("orders", "shop"); err != nil {
		t.Fatal(err)
	}
	a, err := ReadActiveUnpinned()
	if err != nil {
		t.Fatal(err)
	}
	if a.Project != entry.Path || a.Environment != "staging" {
		t.Errorf("active = %+v", a)
	}
}

func TestRemoveProjectKeepsFile(t *testing.T) {
	lifeSetup(t)
	_, entry, err := CreateProject(t.TempDir(), "orders")
	if err != nil {
		t.Fatal(err)
	}
	if err := RemoveProject("orders"); err != nil {
		t.Fatal(err)
	}
	if _, ok := lifeRegistry(t)["orders"]; ok {
		t.Error("row remains")
	}
	if _, err := os.Stat(entry.Path); err != nil {
		t.Errorf("project.json gone: %v", err)
	}
}

func TestRemoveActiveProjectPicksFirstRemaining(t *testing.T) {
	lifeSetup(t)
	_, a, err := CreateProject(t.TempDir(), "a")
	if err != nil {
		t.Fatal(err)
	}
	_, b, err := CreateProject(t.TempDir(), "b")
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: a.Path, Environment: "staging"}); err != nil {
		t.Fatal(err)
	}
	if err := RemoveProject("a"); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadActiveUnpinned()
	if got.Project != b.Path {
		t.Errorf("active project = %q, want %q", got.Project, b.Path)
	}
	if err := RemoveProject("b"); err != nil {
		t.Fatal(err)
	}
	got, _ = ReadActiveUnpinned()
	if got.Project != "" {
		t.Errorf("active project = %q, want empty", got.Project)
	}
}
