package driver

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestPlanTeardownKillsOurOwnInstance(t *testing.T) {
	plan := PlanTeardown(fixtureFor(t), true, nil, "/f/home")
	if !plan.Kill {
		t.Fatal("want Kill for an instance on the fixture HOME")
	}
	if plan.Refusal != nil {
		t.Fatalf("want no refusal, got %v", plan.Refusal)
	}
}

// The operator's instance, or any process we misidentified, must survive.
func TestPlanTeardownRefusesAProcessOnAnotherHome(t *testing.T) {
	plan := PlanTeardown(fixtureFor(t), true, nil, "/Users/operator")
	if plan.Kill {
		t.Fatal("must never kill a process that is not on the fixture HOME")
	}
	if plan.Refusal == nil {
		t.Fatal("want a refusal")
	}
	if !strings.Contains(plan.Refusal.Error(), "/Users/operator") {
		t.Fatalf("refusal must name the HOME it saw, got %q", plan.Refusal)
	}
}

// An instance that already exited is not a failure and not something to kill.
// Before this fix it took the refusal branch, because `ps` returned nothing and
// the empty HOME read as a mismatch.
func TestPlanTeardownIsQuietWhenTheProcessAlreadyExited(t *testing.T) {
	plan := PlanTeardown(fixtureFor(t), false, nil, "")
	if plan.Kill {
		t.Fatal("nothing to kill")
	}
	if plan.Refusal != nil {
		t.Fatalf("an exited process is an ordinary outcome, not a refusal: %v", plan.Refusal)
	}
}

// THE POINT OF THIS FILE. A failure to inspect the process is an
// infrastructure failure and must say so. Reporting it as `its HOME is ""`
// disguises a broken `ps` as a safety decision — the same shape of defect as a
// guard that passes because it could not look.
func TestPlanTeardownDistinguishesAFailedInspectionFromAMismatch(t *testing.T) {
	plan := PlanTeardown(fixtureFor(t), false, errors.New("ps: permission denied"), "")
	if plan.Kill {
		t.Fatal("must not kill on an inspection we could not trust")
	}
	if plan.Refusal == nil {
		t.Fatal("want an error: the inspection failed")
	}
	message := plan.Refusal.Error()
	if !strings.Contains(message, "permission denied") {
		t.Fatalf("must carry the underlying failure, got %q", message)
	}
	if strings.Contains(message, `HOME is ""`) {
		t.Fatalf("must not present an infrastructure failure as a HOME mismatch, got %q", message)
	}
}

// TestProcessAliveAnswersWithoutSpawningAnything is the cheap half of the
// wait, and cheapness is the point: `processEnv` costs a `ps`, and polling it
// per iteration would spawn a process per poll — slow enough to mask the very
// race the wait exists to close, which is the trap `Activate` fell into.
func TestProcessAliveAnswersWithoutSpawningAnything(t *testing.T) {
	if !processAlive(os.Getpid()) {
		t.Error("this test's own process must read as alive")
	}
	// A pid that cannot exist. Signal 0 reports ESRCH, which is "gone".
	if processAlive(1 << 30) {
		t.Error("a pid that does not exist must not read as alive")
	}
}

// TestAwaitExitReturnsAsSoonAsThePidIsGone — the wait is a ceiling reached
// only when something is wrong, never a toll. A teardown that has already
// happened must cost nothing.
func TestAwaitExitReturnsAsSoonAsThePidIsGone(t *testing.T) {
	command := exec.Command("/bin/sh", "-c", "exit 0")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	_ = command.Wait()

	instance := &Instance{PID: command.Process.Pid, Fixture: Fixture{Home: t.TempDir()}}
	started := time.Now()
	if err := instance.awaitExit(); err != nil {
		t.Fatalf("a pid that is already gone must not be an error: %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Errorf("waiting on an exited pid took %s; it must return at once", elapsed)
	}
}

// TestAwaitExitWaitsForAProcessStillOnItsWayOut is the defect itself. `kill`
// returns when the SIGNAL is delivered, not when the process is gone, and
// `refuseStrayFixtures` scans at the start of the next launch — so with
// nothing in between, a single run on a clean machine can refuse ITSELF.
func TestAwaitExitWaitsForAProcessStillOnItsWayOut(t *testing.T) {
	command := exec.Command("/bin/sh", "-c", "sleep 0.3")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill() })
	pid := command.Process.Pid

	go func() { _ = command.Wait() }()
	instance := &Instance{PID: pid, Fixture: Fixture{Home: t.TempDir()}}

	if err := instance.awaitExit(); err != nil {
		t.Fatalf("a process that exits within the deadline is not an error: %v", err)
	}
	// The whole contract: once this returns, a scan must not find it.
	if processAlive(pid) {
		t.Error("awaitExit returned while the process was still in the table — " +
			"which is exactly the window that lets the next launch refuse itself")
	}
}
