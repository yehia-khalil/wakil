package driver

import (
	"strings"
	"testing"
)

// The guards that used to live on a second function called ExpectRed.
//
// **It was deleted because it was a second answer to Verdict.Err's
// question** — `wakil-e2e-new` never called it, and the two derived the same
// missing/silent/passed verdict and formatted it identically. What it carried
// that Verdict did not is a run-level fault, which is now Verdict.Fatal, and
// these are its tests.

// **An unsound run is never a red-required pass.** Everything going red
// because the harness itself could not work is the one outcome that looks
// identical to success from inside a pass that WANTS red, so the run's own
// verdict is consulted first and inverted by nothing.
func TestVerdictRefusesAnUnsoundRun(t *testing.T) {
	verdict := Verdict{}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/a.jsonl"}, Result{
		ChecksRun:  1,
		Assertions: 1,
		Fatal:      []string{`quarantine names "gone.jsonl", which is not among the checks being run`},
		Checks: []CheckOutcome{
			{Name: "a.jsonl", Assertions: 1, Failures: []string{"a step 1: no"}},
		},
	})
	err := verdict.Err()
	if err == nil {
		t.Fatal("want a refusal: the run itself was unsound")
	}
	if !strings.Contains(err.Error(), "unsound") {
		t.Fatalf("got %q", err)
	}
}

// **A launch that executed no check is unsound, not red.** A quarantined
// check is excluded from the outcomes altogether, so without this a branch
// whose only new check was quarantined would certify itself.
func TestVerdictRefusesALaunchThatExecutedNoCheck(t *testing.T) {
	verdict := Verdict{}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/a.jsonl"}, Result{})
	if err := verdict.Err(); err == nil {
		t.Fatal("want a refusal: nothing ran")
	}
}

// A check that asserted nothing is not red however it failed: whatever went
// wrong came from an act, and an act that could not be made against an older
// bundle is not the same claim as an assertion that could not hold there.
func TestVerdictRefusesACheckThatAssertedNothing(t *testing.T) {
	verdict := Verdict{}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/a.jsonl"}, Result{
		ChecksRun: 1,
		Checks: []CheckOutcome{
			{Name: "a.jsonl", Assertions: 0, Failures: []string{"a step 1: the act was refused"}},
		},
	})
	err := verdict.Err()
	if err == nil {
		t.Fatal("want a refusal: the check asserted nothing")
	}
	if !strings.Contains(err.Error(), "asserted nothing") {
		t.Fatalf("got %q", err)
	}
}
