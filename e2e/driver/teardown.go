package driver

import "fmt"

// TeardownPlan is what Close decided to do about the process, having looked at
// it. The keychain is removed either way and is deliberately not part of this:
// it belongs to the run whatever the process turned out to be, and every early
// return that skipped its removal leaked one.
type TeardownPlan struct {
	Kill    bool
	Refusal error
}

// PlanTeardown decides whether the process may be killed.
//
// Three outcomes, and keeping them apart is the point:
//
//   - alive, on the fixture HOME — ours; kill it.
//   - alive, on another HOME — not ours, or misidentified. Never killed, and
//     the refusal is loud, because a stray fixture instance left running is
//     the failure this harness exists to make visible.
//   - already exited — an ordinary outcome, not a refusal.
//
// **And a fourth that used to masquerade as the second.** When the inspection
// itself fails, `ps` returns nothing, the HOME reads as "" and the old code
// reported `refusing to kill pid N: its HOME is ""` — an infrastructure
// failure dressed as a safety decision, which is exactly the shape of defect
// this harness was built to catch. It now says what actually happened.
func PlanTeardown(fixture Fixture, alive bool, inspectErr error, home string) TeardownPlan {
	if inspectErr != nil {
		return TeardownPlan{Refusal: fmt.Errorf(
			"could not inspect the instance to confirm it is ours, so it was left running: %w",
			inspectErr)}
	}
	if !alive {
		return TeardownPlan{}
	}
	if home != fixture.Home {
		return TeardownPlan{Refusal: fmt.Errorf(
			"refusing to kill the instance: its HOME is %q, not the fixture %q — it is not ours",
			home, fixture.Home)}
	}
	return TeardownPlan{Kill: true}
}
