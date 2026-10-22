package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const envLifeJSON = `{"name":"shop","org":"acme","roots":[{"path":"/x"}],"environments":{
"staging":{"databases":[{"name":"orders","ref":"db:p:staging:orders"}],"api":[{"name":"main","url":"https://s.example"}],"production":false},
"prod":{"databases":[],"production":true}}}`

func envLifeProject(t *testing.T, raw string) string {
	t.Helper()
	lifeSetup(t)
	return writeProjectFile(t, t.TempDir(), raw)
}

// stubTrashCopying makes trashBin copy its last argument into a record dir.
func stubTrashCopying(t *testing.T, exit string) string {
	t.Helper()
	rec := t.TempDir()
	bin := filepath.Join(t.TempDir(), "trash")
	script := "#!/bin/sh\nfor a; do last=\"$a\"; done\ncp \"$last\" " + strconv1(rec) + "/\"$(basename \"$last\")\"\n" +
		"dirname \"$last\" > " + strconv1(rec) + "/.from\n" + exit + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := trashBin
	trashBin = bin
	t.Cleanup(func() { trashBin = old })
	return rec
}

func strconv1(s string) string { return "'" + s + "'" }

func TestCreateEnvironmentMintsFirstFreeName(t *testing.T) {
	path := envLifeProject(t, `{"name":"shop","org":"acme","roots":[],"environments":{}}`)
	for _, want := range []string{"new-environment", "new-environment-2", "new-environment-3"} {
		got, err := CreateEnvironment(path)
		if err != nil || got != want {
			t.Fatalf("got %q, %v; want %q", got, err, want)
		}
	}
	p, _ := LoadProject(path)
	env := p.Environments["new-environment"]
	if len(env.Databases) != 0 || len(env.API) != 0 {
		t.Errorf("not empty: %+v", env)
	}
}

func TestRenameEnvironmentKeepsContents(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	if err := RenameEnvironment(path, "staging", " qa "); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadProject(path)
	if _, still := p.Environments["staging"]; still {
		t.Error("old key remains")
	}
	env := p.Environments["qa"]
	if len(env.Databases) != 1 || env.Databases[0].Ref != "db:p:staging:orders" || len(env.API) != 1 || env.Production == nil {
		t.Errorf("contents lost: %+v", env)
	}
}

func TestRenameEnvironmentRefusesClashAndInvalid(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	for _, tc := range []struct{ new, want string }{{"prod", "prod"}, {"  ", "empty"}, {"a/b", "/"}} {
		err := RenameEnvironment(path, "staging", tc.new)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%q: err = %v", tc.new, err)
		}
	}
	if err := RenameEnvironment(path, "nope", "x"); err == nil {
		t.Error("missing env accepted")
	}
	p, _ := LoadProject(path)
	if len(p.Environments) != 2 {
		t.Error("project changed")
	}
}

func TestRenameActiveEnvironmentFollows(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	if err := WriteActive(ActiveContext{Project: path, Environment: "staging"}); err != nil {
		t.Fatal(err)
	}
	if err := RenameEnvironment(path, "staging", "qa"); err != nil {
		t.Fatal(err)
	}
	a, _ := ReadActiveUnpinned()
	if a.Environment != "qa" {
		t.Errorf("active env = %q", a.Environment)
	}
}

func TestRemoveEnvironmentTrashesCopyFirst(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	before, _ := os.ReadFile(path)
	rec := stubTrashCopying(t, "exit 0")
	at := time.Date(2026, 10, 22, 14, 2, 0, 0, time.Local)
	name, err := RemoveEnvironment(path, "staging", at)
	if err != nil {
		t.Fatal(err)
	}
	want := "project.json (before removing staging 14:02)"
	if name != want {
		t.Errorf("name = %q", name)
	}
	got, err := os.ReadFile(filepath.Join(rec, want))
	if err != nil || string(got) != string(before) {
		t.Fatalf("trashed copy: %v %q", err, got)
	}
	// Put Back returns a file to where it was trashed from: beside project.json.
	if from, _ := os.ReadFile(filepath.Join(rec, ".from")); strings.TrimSpace(string(from)) != filepath.Dir(path) {
		t.Errorf("trashed from %q, want %q", strings.TrimSpace(string(from)), filepath.Dir(path))
	}
	p, _ := LoadProject(path)
	if _, still := p.Environments["staging"]; still {
		t.Error("key remains")
	}
}

func TestRemoveEnvironmentTrashFailureRemovesNothing(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	stubTrashCopying(t, "exit 1")
	if _, err := RemoveEnvironment(path, "staging", time.Now()); err == nil {
		t.Fatal("expected error")
	}
	p, _ := LoadProject(path)
	if _, ok := p.Environments["staging"]; !ok {
		t.Error("environment removed despite Trash failure")
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(path), "project.json (*")); len(left) > 0 {
		t.Errorf("copy left beside project.json: %v", left)
	}
}

func TestRemoveActiveEnvironmentPicksFirstRemaining(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	stubTrashCopying(t, "exit 0")
	WriteActive(ActiveContext{Project: path, Environment: "staging"})
	if _, err := RemoveEnvironment(path, "staging", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a, _ := ReadActiveUnpinned(); a.Environment != "prod" {
		t.Errorf("active env = %q", a.Environment)
	}
	if _, err := RemoveEnvironment(path, "prod", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a, _ := ReadActiveUnpinned(); a.Environment != "" {
		t.Errorf("active env = %q", a.Environment)
	}
}

func TestRemoveOtherEnvironmentLeavesActive(t *testing.T) {
	path := envLifeProject(t, envLifeJSON)
	stubTrashCopying(t, "exit 0")
	WriteActive(ActiveContext{Project: path, Environment: "prod"})
	if _, err := RemoveEnvironment(path, "staging", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a, _ := ReadActiveUnpinned(); a.Environment != "prod" {
		t.Errorf("active env = %q", a.Environment)
	}
}

func TestEnvironmentWritersRefuseOtherOrg(t *testing.T) {
	path := envLifeProject(t, strings.Replace(envLifeJSON, `"org":"acme"`, `"org":"other"`, 1))
	stubTrashCopying(t, "exit 0")
	check := func(err error) {
		t.Helper()
		if err == nil || !strings.Contains(err.Error(), "read-only here") {
			t.Errorf("err = %v", err)
		}
	}
	_, err := CreateEnvironment(path)
	check(err)
	check(RenameEnvironment(path, "staging", "qa"))
	_, err = RemoveEnvironment(path, "staging", time.Now())
	check(err)
}
