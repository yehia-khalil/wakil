package driver_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func write(t *testing.T, dir, file, body string) {
	t.Helper()
	full := filepath.Join(dir, file)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestChangedFilesReadsBothSidesOfARename(t *testing.T) {
	repo := t.TempDir()
	git(t, repo, "init", "-q", "-b", "main")
	write(t, repo, "app/Old.swift", `x.accessibilityIdentifier("window.kept")`+"\n")
	write(t, repo, "app/Gone.swift", "struct Gone {}\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-qm", "base")
	base := git(t, repo, "rev-parse", "HEAD")
	git(t, repo, "mv", "app/Old.swift", "app/New.swift")
	write(t, repo, "app/New.swift", `x.accessibilityIdentifier("window.kept")`+"\nlet y = 1\n")
	git(t, repo, "rm", "-q", "app/Gone.swift")
	write(t, repo, "app/Added.swift", "struct Added {}\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-qm", "head")

	changes, err := driver.ChangedFiles(repo, base)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]driver.ChangedFile{}
	for _, c := range changes {
		byPath[c.Path] = c
	}
	renamed := byPath["app/New.swift"]
	if renamed.Status != "R" || !strings.Contains(renamed.Before, "window.kept") || !strings.Contains(renamed.After, "window.kept") {
		t.Fatalf("rename: %+v", renamed)
	}
	if gone := byPath["app/Gone.swift"]; gone.Status != "D" || gone.Before == "" || gone.After != "" {
		t.Fatalf("deletion: %+v", gone)
	}
	if added := byPath["app/Added.swift"]; added.Status != "A" || added.Before != "" || added.After == "" {
		t.Fatalf("addition: %+v", added)
	}
}

func TestNamedSelectionKeepsLaunchOrderAndSaysWhy(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	for _, f := range []string{"e2e/checks/agent/a.jsonl", "e2e/checks/seeded/s.jsonl"} {
		write(t, dir, f, "{}\n")
	}
	sel, err := driver.NamedSelection(driver.SelectModeNamed,
		[]string{"e2e/checks/agent/a.jsonl", "e2e/checks/seeded/s.jsonl"})
	if err != nil {
		t.Fatal(err)
	}
	if got := sel.Files(); got[0] != "e2e/checks/seeded/s.jsonl" {
		t.Fatalf("order %v", got)
	}
	if sel.Mode != driver.SelectModeNamed || sel.Picks[0].Reasons[0] != "named by E2E_ONLY" {
		t.Fatalf("%+v", sel)
	}
}

func TestNamedSelectionRefusesAFileInNoLaunchDirectory(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	write(t, dir, "e2e/checks/stray.jsonl", "{}\n")
	if _, err := driver.NamedSelection(driver.SelectModeNamed, []string{"e2e/checks/stray.jsonl"}); err == nil {
		t.Fatal("a check in no launch directory must be refused")
	}
}

func TestNamedSelectionRefusesAMissingFile(t *testing.T) {
	t.Chdir(t.TempDir())
	// A glob that matched nothing reaches here as itself.
	if _, err := driver.NamedSelection(driver.SelectModeNamed, []string{"e2e/checks/seeded/nope-*.jsonl"}); err == nil {
		t.Fatal("a file that is not there must be refused")
	}
	if _, err := driver.NamedSelection(driver.SelectModeNamed, nil); err == nil {
		t.Fatal("naming nothing must be refused")
	}
}

func TestTheSelectionRecordRoundTrips(t *testing.T) {
	root := t.TempDir()
	if _, ok, err := driver.ReadSelection(root); ok || err != nil {
		t.Fatalf("no record yet: ok=%v err=%v", ok, err)
	}
	want := driver.Selection{Mode: driver.SelectModeSelected, HeadCommit: "abc",
		Picks:    []driver.Pick{{Check: "e2e/checks/seeded/x.jsonl", Reasons: []string{"the check changed"}}},
		Unmapped: []string{"internal/x.go"}}
	path, err := driver.WriteSelection(root, want)
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(root, "select", "latest.json") {
		t.Fatalf("path %s", path)
	}
	got, ok, err := driver.ReadSelection(root)
	if err != nil || !ok || got.HeadCommit != "abc" || !got.Has("e2e/checks/seeded/x.jsonl") || got.Unmapped[0] != "internal/x.go" {
		t.Fatalf("got %+v ok=%v err=%v", got, ok, err)
	}
}

// A hub file spells nearly every action; reading it whole selects nearly
// every check. Only the changed lines and their context count.
func TestChangedFilesReadsTheHunksNotTheWholeFile(t *testing.T) {
	repo := t.TempDir()
	git(t, repo, "init", "-q", "-b", "main")
	lines := []string{`register(name: "far_away")`}
	for i := 0; i < 20; i++ {
		lines = append(lines, "let filler = 0")
	}
	lines = append(lines, `register(name: "near_by")`, "let edited = 1")
	write(t, repo, "app/Hub.swift", strings.Join(lines, "\n")+"\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-qm", "base")
	base := git(t, repo, "rev-parse", "HEAD")
	lines[len(lines)-1] = "let edited = 2"
	write(t, repo, "app/Hub.swift", strings.Join(lines, "\n")+"\n")
	git(t, repo, "commit", "-qam", "head")

	changes, err := driver.ChangedFiles(repo, base)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 {
		t.Fatalf("changes %+v", changes)
	}
	if !strings.Contains(changes[0].After, "near_by") || strings.Contains(changes[0].After, "far_away") {
		t.Fatalf("after side %q", changes[0].After)
	}
	if !strings.Contains(changes[0].Before, "edited = 1") || strings.Contains(changes[0].After, "edited = 1") {
		t.Fatalf("sides: before %q after %q", changes[0].Before, changes[0].After)
	}
}

func TestNamedSelectionRefusesWhatIsNotACheckFile(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	write(t, dir, "e2e/checks/seeded/a.jsonl", "{}\n")
	write(t, dir, "Makefile", "x\n")
	for _, named := range []string{"e2e/checks/seeded/", "e2e/checks/seeded/../../../Makefile"} {
		if _, err := driver.NamedSelection(driver.SelectModeNamed, []string{named}); err == nil {
			t.Errorf("%s must be refused", named)
		}
	}
}

func TestNamedSelectionRunsANameOnce(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	write(t, dir, "e2e/checks/seeded/a.jsonl", "{}\n")
	sel, err := driver.NamedSelection(driver.SelectModeNamed,
		[]string{"e2e/checks/seeded/a.jsonl", "./e2e/checks/seeded/a.jsonl"})
	if err != nil {
		t.Fatal(err)
	}
	if len(sel.Picks) != 1 || sel.Picks[0].Check != "e2e/checks/seeded/a.jsonl" {
		t.Fatalf("picks %+v", sel.Picks)
	}
}
