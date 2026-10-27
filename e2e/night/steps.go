package night

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"text/template"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

//go:embed fixer-prompt.md
var fixerPrompt string

var fixerTemplate = template.Must(template.New("fixer").Parse(fixerPrompt))

// FixerPrompt renders the fixer's instructions for one night.
func FixerPrompt(in FixInput) (string, error) {
	var b strings.Builder
	err := fixerTemplate.Execute(&b, in)
	return b.String(), err
}

// The screen is quiet once no e2e has held it for this long, polled this often:
// a daytime run is briefly absent between two check files.
const (
	quietFor  = 2 * time.Minute
	quietPoll = 30 * time.Second
)

// NightWorktree is the worktree the night run owns, beside the repository.
func NightWorktree(commonDir string) string {
	return filepath.Dir(commonDir) + "-night"
}

// RealSteps are the night's steps on this Mac. Output goes to out, which the
// launchd job sends to night.log.
func RealSteps(repo string, store Store, out io.Writer) (Steps, error) {
	common, err := CommonDir(repo)
	if err != nil {
		return Steps{}, err
	}
	wt := NightWorktree(common)
	return Steps{
		Now: time.Now,
		ScreenQuiet: func(until time.Time) (bool, error) {
			return WaitQuiet(ScreenBusy, time.Now, time.Sleep, until)
		},
		Fetch: func() (string, error) {
			if _, err := gitOut(repo, "fetch", "--quiet", "origin"); err != nil {
				return "", err
			}
			return gitOut(repo, "rev-parse", "origin/main")
		},
		Prepare: func(commit string) error { return PrepareWorktree(repo, wt, commit) },
		Suite: func(deadline time.Time) (SuiteRun, error) {
			return suite(wt, deadline, out, []string{"e2e-full", "E2E_KEEP_GOING=1"})
		},
		Branch: func(name, at string) error {
			_, err := gitOut(wt, "checkout", "--quiet", "-B", name, at)
			return err
		},
		Unmerged: func(main string) ([]string, error) { return UnmergedNightBranches(repo, main) },
		Fix: func(in FixInput) error {
			prompt, err := FixerPrompt(in)
			if err != nil {
				return err
			}
			claude, err := exec.LookPath("claude")
			if err != nil {
				return err
			}
			timedOut, _, err := runUntil(wt, in.Deadline, out, claude, "-p", prompt, "--permission-mode", "bypassPermissions")
			if timedOut {
				return fmt.Errorf("stopped at %s to leave time for the re-run", in.Deadline.Format("15:04"))
			}
			return err
		},
		Commits: func(since string) ([]string, error) {
			log, err := gitOut(wt, "log", "--format=%h %s", since+"..HEAD")
			if err != nil || log == "" {
				return nil, err
			}
			return strings.Split(log, "\n"), nil
		},
		DropBranch: func(name string) error {
			if _, err := gitOut(wt, "checkout", "--quiet", "--detach"); err != nil {
				return err
			}
			_, err := gitOut(wt, "branch", "-D", name)
			return err
		},
		Rerun: func(files []string, deadline time.Time) (SuiteRun, error) {
			return suite(wt, deadline, out, []string{"e2e", "E2E_ONLY=" + strings.Join(files, " "), "E2E_KEEP_GOING=1"})
		},
	}, nil
}

// suite runs one make target over the checks in wt until deadline and reads
// back what went red. A make that failed with no red check and a green
// coverage gate (a bundle that did not build, say) is an error, never a run.
func suite(wt string, deadline time.Time, out io.Writer, args []string) (SuiteRun, error) {
	start := time.Now()
	timedOut, _, err := runUntil(wt, deadline, out, "make", args...)
	if timedOut {
		TearDownFixtures()
	}
	var exit *exec.ExitError
	if err != nil && !errors.As(err, &exit) && !timedOut {
		return SuiteRun{}, err
	}
	red, readErr := RedFilesSince(filepath.Join(wt, driver.DefaultEvidenceRoot), start)
	if readErr != nil {
		return SuiteRun{}, readErr
	}
	run := SuiteRun{Red: red, TimedOut: timedOut}
	if timedOut || err == nil {
		return run, nil
	}
	var cover bytes.Buffer
	if _, _, coverErr := runUntil(wt, deadline, io.MultiWriter(out, &cover), "make", "e2e-cover"); coverErr != nil {
		run.CoverRed = cover.String()
	}
	if len(run.Red) == 0 && run.CoverRed == "" {
		return run, fmt.Errorf("make %s failed with no red check and a green coverage gate (see night.log): %w",
			strings.Join(args, " "), err)
	}
	return run, nil
}

// runUntil runs a command in dir in its own process group, killing the whole
// group at deadline. It returns the group id so a caller can confirm it is gone.
func runUntil(dir string, deadline time.Time, out io.Writer, name string, args ...string) (timedOut bool, pgid int, err error) {
	cmd := exec.Command(name, args...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = dir, out, out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return false, 0, err
	}
	pgid = cmd.Process.Pid
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return false, pgid, err
	case <-time.After(time.Until(deadline)):
	}
	syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case err = <-done:
	case <-time.After(10 * time.Second):
		syscall.Kill(-pgid, syscall.SIGKILL)
		err = <-done
	}
	syscall.Kill(-pgid, syscall.SIGKILL) // a child that ignored SIGTERM
	return true, pgid, fmt.Errorf("stopped at %s: %w", deadline.Format("15:04"), err)
}

// TearDownFixtures quits any Wakil instance a killed run left open. The harness
// counts any command line containing this path as a fixture.
func TearDownFixtures() {
	exec.Command("pkill", "-f", "WakilE2E.app/Contents/MacOS/").Run()
}

// ScreenBusy says whether any e2e run holds the screen: a Wakil fixture, or a
// driver between two of its launches.
func ScreenBusy() (bool, error) {
	for _, pattern := range []string{"[W]akilE2E.app/Contents/MacOS/", "[e]2e/cmd/wakil-e2e( |$)"} {
		err := exec.Command("pgrep", "-f", pattern).Run()
		if err == nil {
			return true, nil
		}
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 1 {
			return false, fmt.Errorf("pgrep %s: %w", pattern, err)
		}
	}
	return false, nil
}

// WaitQuiet returns true once busy has been false for quietFor without a
// break, and false if until comes first.
func WaitQuiet(busy func() (bool, error), now func() time.Time, sleep func(time.Duration), until time.Time) (bool, error) {
	var quietSince time.Time
	for !now().After(until) {
		b, err := busy()
		if err != nil {
			return false, err
		}
		switch {
		case b:
			quietSince = time.Time{}
		case quietSince.IsZero():
			quietSince = now()
		}
		if !quietSince.IsZero() && now().Sub(quietSince) >= quietFor {
			return true, nil
		}
		sleep(quietPoll)
	}
	return false, nil
}

// PrepareWorktree puts the night worktree at path on commit, detached, with
// tracked changes and untracked files gone. Ignored files (.context/, where the
// run records live) are kept.
func PrepareWorktree(repo, path, commit string) error {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		_, err := gitOut(repo, "worktree", "add", "--quiet", "--detach", path, commit)
		return err
	}
	if _, err := gitOut(path, "checkout", "--quiet", "--detach", "--force", commit); err != nil {
		return err
	}
	_, err := gitOut(path, "clean", "-fdq")
	return err
}

// UnmergedNightBranches lists the e2e-night/* branches not merged into main.
func UnmergedNightBranches(repo, main string) ([]string, error) {
	out, err := gitOut(repo, "branch", "--list", "e2e-night/*", "--no-merged", main, "--format=%(refname:short)")
	if err != nil || out == "" {
		return nil, err
	}
	return strings.Split(out, "\n"), nil
}

func gitOut(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}
