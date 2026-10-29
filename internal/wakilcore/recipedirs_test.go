package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRepoNamesFromRelativeRoots(t *testing.T) {
	proj := filepath.Join(t.TempDir(), "estate")
	path := filepath.Join(proj, ".wakil", "project.json")
	os.MkdirAll(filepath.Dir(path), 0o755)
	os.WriteFile(path, []byte(`{"name":"estate","org":"initech","roots":[{"path":".","recipe":"go"},{"path":"../web"}],"recipes":{"go":{"processes":[{"name":"app","command":"go run ."}]}}}`), 0o600)
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := RepoNameIn(path, p.Roots[0]); got != "estate" {
		t.Fatalf("a root of . is the project folder: %q", got)
	}
	if _, err := EffectiveRecipe(*p, "estate"); err != nil {
		t.Fatalf("effective by folder name: %v", err)
	}
	dirs := RepoDirs(path, *p)
	if dirs["estate"] != proj || dirs["web"] != filepath.Join(filepath.Dir(proj), "web") {
		t.Fatalf("dirs: %v", dirs)
	}
}

func TestConfineRunDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	repo := filepath.Join(home, "src", "api")
	ws := filepath.Join(home, ".wakil", "orgs", "initech", "workspaces", "estate", "ini-142", "api")
	os.MkdirAll(repo, 0o755)
	os.MkdirAll(ws, 0o755)
	dirs := map[string]string{"api": repo}
	for _, ok := range []string{repo, filepath.Join(repo, "sub"), ws} {
		if err := ConfineRunDir(ok, "initech", dirs); err != nil {
			t.Errorf("%s refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"/etc", filepath.Join(home, "src"), "relative", filepath.Join(home, "src", "api2")} {
		if err := ConfineRunDir(bad, "initech", dirs); err == nil {
			t.Errorf("%s allowed", bad)
		}
	}
	link := filepath.Join(repo, "escape")
	os.Symlink("/etc", link)
	if err := ConfineRunDir(link, "initech", dirs); err == nil || !strings.Contains(err.Error(), "Invariant 6") {
		t.Errorf("a link out is refused: %v", err)
	}
}

func TestComposeOverrideForDirWithoutAComposeFile(t *testing.T) {
	res, err := ComposeOverrideForDir(t.TempDir(), "w", "web", 41200, nil)
	if err != nil || res.YAML != "" || res.ProjectName != "w-web" {
		t.Fatalf("%+v %v", res, err)
	}
}
