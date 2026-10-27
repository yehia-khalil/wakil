package night

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func commit(t *testing.T, repo, file, body string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(repo, file), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", file)
	git(t, repo, "commit", "-qm", file+" "+body)
	return strings.TrimSpace(git(t, repo, "rev-parse", "HEAD"))
}

func TestTheNightWorktreeSitsBesideTheRepository(t *testing.T) {
	if got := NightWorktree("/Users/yehia/Desktop/scripts/wakil-public/.git"); got != "/Users/yehia/Desktop/scripts/wakil-public-night" {
		t.Fatalf("NightWorktree = %s", got)
	}
}

func TestPrepareResetsTheNightWorktreeAndKeepsItsRecords(t *testing.T) {
	repo := gitRepo(t)
	first := commit(t, repo, "f.txt", "one")
	second := commit(t, repo, "f.txt", "two")
	wt := filepath.Join(filepath.Dir(repo), "night")
	if err := PrepareWorktree(repo, wt, first); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(wt, "f.txt"), []byte("dirty"), 0o644)
	os.WriteFile(filepath.Join(wt, "stray.txt"), []byte("x"), 0o644)
	if err := PrepareWorktree(repo, wt, second); err != nil {
		t.Fatal(err)
	}
	if head := strings.TrimSpace(git(t, wt, "rev-parse", "HEAD")); head != second {
		t.Fatalf("HEAD %s, want %s", head, second)
	}
	if body, _ := os.ReadFile(filepath.Join(wt, "f.txt")); string(body) != "two" {
		t.Fatalf("f.txt = %q", body)
	}
	if _, err := os.Stat(filepath.Join(wt, "stray.txt")); err == nil {
		t.Fatal("untracked file survived")
	}
}

func TestPrepareKeepsIgnoredRecords(t *testing.T) {
	repo := gitRepo(t)
	os.WriteFile(filepath.Join(repo, ".gitignore"), []byte(".context/\n"), 0o644)
	git(t, repo, "add", ".gitignore")
	git(t, repo, "commit", "-qm", "ignore")
	first := commit(t, repo, "f.txt", "one")
	wt := filepath.Join(filepath.Dir(repo), "night")
	if err := PrepareWorktree(repo, wt, first); err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(wt, ".context"), 0o755)
	os.WriteFile(filepath.Join(wt, ".context", "keep"), []byte("x"), 0o644)
	if err := PrepareWorktree(repo, wt, commit(t, repo, "f.txt", "two")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(wt, ".context", "keep")); err != nil {
		t.Fatalf(".context did not survive: %v", err)
	}
}

func TestUnmergedNightBranchesListsOnlyTheOnesNotOnMain(t *testing.T) {
	repo := gitRepo(t)
	commit(t, repo, "f.txt", "one")
	git(t, repo, "branch", "e2e-night/2026-10-26")
	git(t, repo, "checkout", "-qb", "e2e-night/2026-10-25")
	commit(t, repo, "g.txt", "fix")
	git(t, repo, "checkout", "-q", "main")
	got, err := UnmergedNightBranches(repo, "main")
	if err != nil || strings.Join(got, ",") != "e2e-night/2026-10-25" {
		t.Fatalf("unmerged = %v, %v", got, err)
	}
}

func TestWaitQuietWantsTwoQuietMinutesNotOneEmptyPoll(t *testing.T) {
	start := at(27, 23, 0)
	now := start
	pattern := []bool{true, false, true, false, false, false, false, false}
	polls := 0
	busy := func() (bool, error) {
		b := pattern[polls]
		polls++
		return b, nil
	}
	quiet, err := WaitQuiet(busy, func() time.Time { return now }, func(d time.Duration) { now = now.Add(d) }, Deadline(start))
	if err != nil || !quiet {
		t.Fatalf("quiet %v, %v", quiet, err)
	}
	if got := now.Sub(start); got != 210*time.Second {
		t.Fatalf("returned after %s, want 3m30s (quiet from 1m30s for two minutes)", got)
	}
}

func TestWaitQuietGivesUpAtTheDeadline(t *testing.T) {
	now := at(28, 6, 50)
	quiet, err := WaitQuiet(func() (bool, error) { return true, nil },
		func() time.Time { return now }, func(d time.Duration) { now = now.Add(d) }, at(28, 7, 0))
	if err != nil || quiet {
		t.Fatalf("quiet %v, %v", quiet, err)
	}
}

func TestRunUntilKillsTheWholeProcessGroupAtTheDeadline(t *testing.T) {
	began := time.Now()
	timedOut, pgid, err := runUntil(t.TempDir(), began.Add(time.Second), io.Discard, "sh", "-c", "sleep 30 & sleep 30")
	if !timedOut || err == nil {
		t.Fatalf("timedOut %v, err %v", timedOut, err)
	}
	if took := time.Since(began); took > 5*time.Second {
		t.Fatalf("took %s", took)
	}
	time.Sleep(200 * time.Millisecond)
	if out, _ := exec.Command("pgrep", "-g", strconv.Itoa(pgid)).Output(); len(out) > 0 {
		t.Fatalf("processes left in the group: %s", out)
	}
}

func TestASuiteThatFailsWithNoRedCheckIsAnError(t *testing.T) {
	bin := t.TempDir()
	os.WriteFile(filepath.Join(bin, "make"), []byte("#!/bin/sh\n[ \"$1\" = e2e-cover ] && exit 0\necho 'app-bundle: build failed'\nexit 2\n"), 0o755)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	_, err := suite(t.TempDir(), at(28, 7, 0).Add(24*time.Hour), io.Discard, []string{"e2e-full", "E2E_KEEP_GOING=1"})
	if err == nil {
		t.Fatal("a make that failed with no red check and no coverage red read as a run")
	}
}

func TestTheFixerPromptCarriesTheRulesAndTheFailures(t *testing.T) {
	prompt, err := FixerPrompt(FixInput{
		Branch: "e2e-night/2026-10-27", Main: "abc",
		Red:         []RedFile{{File: "e2e/checks/seeded/a.jsonl", Note: "a broke", Evidence: ".context/e2e/x"}},
		Unmerged:    []string{"e2e-night/2026-10-25"},
		SummaryPath: "/tmp/summary.md",
		Deadline:    at(28, 6, 40),
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"e2e/checks/seeded/a.jsonl", "a broke", ".context/e2e/x", "e2e-night/2026-10-25",
		"/tmp/summary.md", "06:40", "Never retries a check into green", "never pushes",
		"Fixes the **code**, not the check",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt is missing %q", want)
		}
	}
}
