package night

import (
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func gitRepo(t *testing.T) string {
	t.Helper()
	// t.TempDir is under /var, a symlink to /private/var; git reports the
	// resolved path, so the test compares against that.
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	git(t, dir, "init", "-q", "-b", "main")
	git(t, dir, "config", "user.email", "night@example.invalid")
	git(t, dir, "config", "user.name", "night")
	return dir
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func TestTheStoreLivesUnderTheGitCommonDirAndKeepsLastGreen(t *testing.T) {
	repo := gitRepo(t)
	store, err := OpenStore(repo)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(repo, ".git", "wakil-e2e-night"); store.Dir != want {
		t.Fatalf("store at %s, want %s", store.Dir, want)
	}
	if got, err := store.LastGreen(); err != nil || got != "" {
		t.Fatalf("fresh LastGreen = %q, %v", got, err)
	}
	if err := store.SetLastGreen("abc"); err != nil {
		t.Fatal(err)
	}
	if got, _ := store.LastGreen(); got != "abc" {
		t.Fatalf("LastGreen = %q", got)
	}
}

func TestLatestIsTheLastNightsResult(t *testing.T) {
	store, err := OpenStore(gitRepo(t))
	if err != nil {
		t.Fatal(err)
	}
	path, err := store.WriteResult(Result{Night: at(26, 0, 0), Outcome: NotPending})
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != "2026-10-26.md" {
		t.Fatalf("result written to %s", path)
	}
	if _, err := store.WriteResult(Result{Night: at(27, 0, 0), Outcome: Green, Main: "feed"}); err != nil {
		t.Fatal(err)
	}
	night, body, err := store.Latest()
	if err != nil || !night.Equal(at(27, 0, 0)) || body == "" {
		t.Fatalf("Latest = %s, %q, %v", night, body, err)
	}
}

func TestLatestWithNoNightsIsTheZeroTime(t *testing.T) {
	store, _ := OpenStore(gitRepo(t))
	night, _, err := store.Latest()
	if err != nil || !night.IsZero() {
		t.Fatalf("Latest = %s, %v", night, err)
	}
}

func TestRedFilesSinceReadsOnlyThisRunsRedRecords(t *testing.T) {
	root := t.TempDir()
	since := time.Now().UTC()
	for _, r := range []driver.RunRecord{
		{RanAt: since.Add(time.Minute), File: "e2e/checks/seeded/green.jsonl", Exit: 0},
		{RanAt: since.Add(-time.Hour), File: "e2e/checks/seeded/old.jsonl", Exit: 1},
		{RanAt: since.Add(time.Minute), File: "e2e/checks/seeded/red.jsonl", Exit: 1, Note: "boom", Evidence: "ev"},
	} {
		if _, err := driver.WriteRunRecord(root, r); err != nil {
			t.Fatal(err)
		}
	}
	red, err := RedFilesSince(root, since)
	if err != nil {
		t.Fatal(err)
	}
	if len(red) != 1 || red[0].File != "e2e/checks/seeded/red.jsonl" || red[0].Note != "boom" || red[0].Evidence != "ev" {
		t.Fatalf("red = %+v", red)
	}
}
