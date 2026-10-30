package night

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
	if got := NightWorktree("/home/op/src/wakil/.git"); got != "/home/op/src/wakil-night" {
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
	timedOut, pgid, err := runUntil(command(t.TempDir(), io.Discard, "sh", "-c", "sleep 30 & sleep 30"), began.Add(time.Second))
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
	_, err := suite(t.TempDir(), time.Now().Add(time.Minute), io.Discard, []string{"e2e-full", "E2E_KEEP_GOING=1"})
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
		"/tmp/summary.md", "06:40", "Never retries a check into green", "Never push",
		"Fixes the **code**, not the check",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt is missing %q", want)
		}
	}
}

func TestTheFixerCannotPush(t *testing.T) {
	remote := gitRepo(t)
	commit(t, remote, "f.txt", "one")
	git(t, remote, "checkout", "-q", "--detach")
	local := filepath.Join(filepath.Dir(remote), "clone")
	if out, err := exec.Command("git", "clone", "-q", remote, local).CombinedOutput(); err != nil {
		t.Fatalf("clone: %v %s", err, out)
	}
	git(t, local, "config", "user.email", "n@example.invalid")
	git(t, local, "config", "user.name", "n")
	commit(t, local, "g.txt", "fix")
	push := exec.Command("git", "-C", local, "push", "-q", "origin", "HEAD:refs/heads/main")
	push.Env = fixerEnv(os.Environ())
	if out, err := push.CombinedOutput(); err == nil {
		t.Fatalf("the fixer's environment pushed: %s", out)
	}
	cmd := fixerCommand(local, "/x/claude", "prompt")
	if !strings.Contains(strings.Join(cmd.Args, " "), "--disallowedTools") {
		t.Fatalf("args %v", cmd.Args)
	}
	if !strings.Contains(strings.Join(cmd.Env, "\n"), "GH_TOKEN=") {
		t.Fatal("gh is not cut off")
	}
}

func TestTheScreenIsBusyWhileAnyE2ERunsOrBuilds(t *testing.T) {
	busy := []string{
		"/Users/x/.context/e2e/bundles/abc/WakilE2E.app/Contents/MacOS/Wakil",
		"go run ./e2e/cmd/wakil-e2e --bundle x e2e/checks/seeded/a.jsonl",
		"go run ./e2e/cmd/wakil-e2e-new --trunk origin/main",
		"go run ./e2e/cmd/wakil-e2e-select --trunk origin/main",
		"make e2e", "make e2e-new", "make e2e-full E2E_KEEP_GOING=1", "make --no-print-directory e2e-run E2E_FILES=a",
	}
	quiet := []string{"make e2e-night-status", "/x/bin/wakil-e2e-night run --repo /x", "make test", "vim e2e/night/run.go"}
	matches := func(line string) bool {
		for _, p := range busyPatterns {
			if regexp.MustCompile(p).MatchString(line) {
				return true
			}
		}
		return false
	}
	for _, line := range busy {
		if !matches(line) {
			t.Errorf("not seen as busy: %s", line)
		}
	}
	for _, line := range quiet {
		if matches(line) {
			t.Errorf("seen as busy: %s", line)
		}
	}
}

func TestInstallKeepsTheBinaryWhenNothingChanged(t *testing.T) {
	dir := t.TempDir()
	dst, fresh := filepath.Join(dir, "bin"), filepath.Join(dir, "fresh")
	os.WriteFile(dst, []byte("same"), 0o755)
	before, _ := os.Stat(dst)
	os.WriteFile(fresh, []byte("same"), 0o755)
	if changed, err := ReplaceIfChanged(fresh, dst); err != nil || changed {
		t.Fatalf("changed %v, %v", changed, err)
	}
	if after, _ := os.Stat(dst); !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("an identical binary was replaced, which would drop its privacy grants")
	}
	os.WriteFile(fresh, []byte("new"), 0o755)
	if changed, err := ReplaceIfChanged(fresh, dst); err != nil || !changed {
		t.Fatalf("changed %v, %v", changed, err)
	}
	if body, _ := os.ReadFile(dst); string(body) != "new" {
		t.Fatalf("dst = %q", body)
	}
}

func TestAnUntrustedAxresolveIsNoAccessibility(t *testing.T) {
	denied := []byte(`{"ok":false,"error":"accessibility_denied","message":"not trusted"}`)
	if err := axTrusted("/x/bin/wakil-e2e-night", denied); err == nil || !strings.Contains(err.Error(), "/x/bin/wakil-e2e-night") {
		t.Fatalf("err %v", err)
	}
	if err := axTrusted("/x/bin/wakil-e2e-night", []byte(`{"ok":true,"pid":1}`)); err != nil {
		t.Fatalf("err %v", err)
	}
}
