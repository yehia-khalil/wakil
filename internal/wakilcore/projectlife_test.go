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
	entry, err := CreateProject(folder, " orders ")
	if err != nil {
		t.Fatal(err)
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
	if _, err := CreateProject(folder, "orders"); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Errorf("the adopted file was rewritten:\n%s\n---\n%s", before, after)
	}
	p, _ := LoadProject(path)
	if len(p.Environments) != 2 {
		t.Errorf("environments lost: %+v", p.Environments)
	}
	if _, ok := lifeRegistry(t)["orders"]; !ok {
		t.Error("no registry row")
	}
}

func TestCreateProjectRefusesOtherOrg(t *testing.T) {
	lifeSetup(t)
	folder := t.TempDir()
	writeProjectFile(t, folder, `{"name":"x","org":"other","roots":[],"environments":{}}`)
	_, err := CreateProject(folder, "orders")
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
	if _, err := CreateProject(folder, "first"); err != nil {
		t.Fatal(err)
	}
	_, err := CreateProject(folder, "second")
	if err == nil || !strings.Contains(err.Error(), `"first"`) {
		t.Fatalf("err = %v", err)
	}
	if _, ok := lifeRegistry(t)["second"]; ok {
		t.Error("second was registered")
	}
}

func TestCreateProjectRefusesNameClash(t *testing.T) {
	lifeSetup(t)
	if _, err := CreateProject(t.TempDir(), "orders"); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	_, err := CreateProject(other, "orders")
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
	if _, err := CreateProject(folder, "orders"); err != nil {
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
	if _, err := CreateProject(folder, "orders"); err != nil {
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
	entry, err := CreateProject(t.TempDir(), "orders")
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
	entry, err := CreateProject(t.TempDir(), "orders")
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
	a, err := CreateProject(t.TempDir(), "a")
	if err != nil {
		t.Fatal(err)
	}
	b, err := CreateProject(t.TempDir(), "b")
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
