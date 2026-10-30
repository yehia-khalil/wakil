package driver

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// startFakeStagedApp starts a sleeping process whose argv looks exactly like a
// staged fixture's — the whole of what `pgrep -f` matches on — under root.
//
// **Under this test binary's own bundle name, not StagedBundleName.** The
// stray scan reads the whole machine, so with the shared name a second `go
// test` of this package (another worktree, two runs at once) or a real e2e
// run put its instances in this test's counts, and the clean-machine test
// failed whenever two ran together. The scan is pointed at the same name for
// the length of the test; nothing else on the machine runs it.
func startFakeStagedApp(t *testing.T, root string) (string, *exec.Cmd) {
	t.Helper()
	previous := strayBundleName
	strayBundleName = fmt.Sprintf("WakilE2E-test%d.app", os.Getpid())
	t.Cleanup(func() { strayBundleName = previous })
	bundle := filepath.Join(root, strayBundleName)
	macos := filepath.Join(bundle, "Contents", "MacOS")
	if err := os.MkdirAll(macos, 0o755); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(macos, "Wakil")
	// **`sleep 5` caps how long an INTERRUPTED run leaves a decoy behind**,
	// where Cleanup never fires. Its bundle name is this binary's own, so a
	// leftover no longer stops `make e2e`; the cap keeps the table clean.
	//
	// Measured 2026-09-26: `/bin/sh` FORKS rather than execs, so killing it
	// leaves the `sleep` as an orphan — but that orphan's argv is a bare
	// `sleep`, which the stray scan's pattern cannot match, so it is
	// harmless. The SHELL is the decoy. Five seconds only has to outlive
	// `waitForPgrep`, which gives up at five.
	//
	// A `trap` would NOT help: `t.Cleanup` calls `Process.Kill()`, which is
	// SIGKILL, and SIGKILL runs no handler.
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nsleep 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(binary)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_, _ = command.Process.Wait()
	})
	// pgrep reads the process table, which the fork above has not reached yet.
	waitForPgrep(t, binary)
	return bundle, command
}

func waitForPgrep(t *testing.T, pattern string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if pids, err := pgrep(pattern); err == nil && len(pids) > 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no process matching %q ever appeared", pattern)
}

// TestStrayFixturesSeesAnotherRunsInstance is the defect this guard was built
// for, and the common case is two agents running `make e2e` at once rather
// than a leftover. Each run stages its own copy under a fresh root, so the two
// bundles below share no path — which is exactly why `runningPIDs`, scoped to
// one path, reports nothing and the other instance goes unnamed. What they DO
// share is the bundle identifier, and that is what lets it take the
// foreground.
func TestStrayFixturesSeesAnotherRunsInstance(t *testing.T) {
	previousRun, previous := startFakeStagedApp(t, t.TempDir())
	thisRun, _ := startFakeStagedApp(t, t.TempDir())

	// The premise: the guard that exists cannot see it.
	mine, err := runningPIDs(thisRun)
	if err != nil {
		t.Fatal(err)
	}
	for _, pid := range mine {
		if pid == previous.Process.Pid {
			t.Fatal("the two staged copies must live at different paths for this test to mean anything")
		}
	}

	strays, err := StrayFixtures(thisRun)
	if err != nil {
		t.Fatal(err)
	}
	if !containsInt(strays, previous.Process.Pid) {
		t.Errorf("the stray at %s (pid %d) was not reported: %v",
			previousRun, previous.Process.Pid, strays)
	}
}

// TestStrayFixturesDoesNotReportThisRunsOwnInstance — the other half. A guard
// that reports the launch's own process refuses every launch, which is a
// worse failure than the one it prevents.
func TestStrayFixturesDoesNotReportThisRunsOwnInstance(t *testing.T) {
	thisRun, mine := startFakeStagedApp(t, t.TempDir())

	strays, err := StrayFixtures(thisRun)
	if err != nil {
		t.Fatal(err)
	}
	if containsInt(strays, mine.Process.Pid) {
		t.Errorf("the launch's own instance (pid %d) was reported as a stray: %v",
			mine.Process.Pid, strays)
	}
}

// TestRefuseStrayFixturesNamesThePidsAndHowToClearThem. The refusal is read by
// someone whose run just stopped, so it has to carry the remedy — the pids
// are not discoverable by any command this harness has told them about, and
// the right move is often to wait rather than to kill anything.
func TestRefuseStrayFixturesNamesThePidsAndHowToClearThem(t *testing.T) {
	_, previous := startFakeStagedApp(t, t.TempDir())
	thisRun, _ := startFakeStagedApp(t, t.TempDir())

	err := refuseStrayFixtures(thisRun)
	if err == nil {
		t.Fatal("a launch racing a leftover instance must be refused")
	}
	pid := strconv.Itoa(previous.Process.Pid)
	if !strings.Contains(err.Error(), pid) {
		t.Errorf("the refusal must name the stray's pid %s: %v", pid, err)
	}
	if !strings.Contains(err.Error(), "kill") {
		t.Errorf("the refusal must say how to clear the stray: %v", err)
	}
}

// TestRefuseStrayFixturesPassesWhenTheMachineIsClean, so the guard cannot be
// satisfied by refusing unconditionally — which would stop every run on a
// machine that has never had two.
func TestRefuseStrayFixturesPassesWhenTheMachineIsClean(t *testing.T) {
	thisRun, _ := startFakeStagedApp(t, t.TempDir())

	if err := refuseStrayFixtures(thisRun); err != nil {
		t.Errorf("a clean machine must not be refused: %v", err)
	}
}

func containsInt(values []int, want int) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
