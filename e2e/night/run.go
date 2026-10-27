package night

import (
	"fmt"
	"os"
	"time"
)

// FixInput is what the overnight fixer is handed.
type FixInput struct {
	Branch, Main string
	Red          []RedFile
	CoverRed     string
	// Unmerged are earlier e2e-night/* branches not merged into Main: a
	// failure one of them already fixes is pointed at, not fixed again.
	Unmerged []string
	// SummaryPath is where the fixer writes its summary and PR draft.
	SummaryPath string
	// Deadline leaves room for the re-run before 07:00.
	Deadline time.Time
}

// Steps are the night's effects. Run sequences them; RealSteps is the Mac's.
type Steps struct {
	Now func() time.Time
	// ScreenQuiet waits until no e2e holds the screen, and is false when one
	// still does at until.
	ScreenQuiet func(until time.Time) (bool, error)
	// Fetch fetches origin and returns origin/main's commit.
	Fetch func() (main string, err error)
	// Preflight fails when this job cannot drive the window at all (no
	// Accessibility grant), so a night that could test nothing says so.
	Preflight func() error
	// Prepare puts the night worktree on commit, detached and clean.
	Prepare    func(commit string) error
	Suite      func(deadline time.Time) (SuiteRun, error)
	Branch     func(name, at string) error
	Unmerged   func(main string) ([]string, error)
	Fix        func(in FixInput) error
	Commits    func(since string) ([]string, error)
	DropBranch func(name string) error
	Rerun      func(files []string, deadline time.Time) (SuiteRun, error)
}

// RerunEstimate is how long re-running n red files takes: a bundle build and
// a few minutes a file. The fixer stops this long before 07:00, and the
// re-run is not started with less than this left.
func RerunEstimate(n int) time.Duration {
	return 15*time.Minute + time.Duration(n)*5*time.Minute
}

// SuiteEstimate is how long `make e2e-full` takes. A suite that could not
// finish by 07:00 is not started.
const SuiteEstimate = time.Hour

// Run is one night, from the window to the result, which it writes to store.
// A start outside the window is filed under the night it missed, and never
// overwrites a night that did run.
func Run(steps Steps, store Store) Result {
	outside := !InWindow(steps.Now())
	r := night(steps, store)
	if _, err := os.Stat(store.ResultPath(r.Night)); outside && err == nil {
		return r
	}
	if _, err := store.WriteResult(r); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-night: writing the result:", err)
	}
	return r
}

func night(steps Steps, store Store) Result {
	now := steps.Now()
	r := Result{Night: NightOf(now)}
	if !InWindow(now) {
		r.Night = LastNight(now)
		r.Outcome, r.Reason = DidNotStart, fmt.Sprintf(
			"Started at %s, outside the night (23:00 to 07:00); the Mac was probably asleep at 23:00.",
			now.Format("15:04"))
		return r
	}
	deadline := Deadline(now)
	didNotStart := func(why string, err error) Result {
		r.Outcome, r.Reason = DidNotStart, why
		if err != nil {
			r.Reason += ": " + err.Error()
		}
		return r
	}

	quiet, err := steps.ScreenQuiet(deadline)
	if err != nil || !quiet {
		return didNotStart("The screen was not free for two quiet minutes before 07:00", err)
	}
	if late := steps.Now(); late.Add(SuiteEstimate).After(deadline) {
		return didNotStart(fmt.Sprintf(
			"Ready at %s, too late for the full run (about an hour) to finish by 07:00", late.Format("15:04")), nil)
	}
	main, err := steps.Fetch()
	if err != nil {
		return didNotStart("Fetching origin failed", err)
	}
	r.Main = main
	lastGreen, err := store.LastGreen()
	if err != nil {
		return didNotStart("Reading the last green night failed", err)
	}
	if main == lastGreen {
		r.Outcome, r.Reason = NotPending, "origin/main has not moved since the last green night."
		return r
	}
	if err := steps.Prepare(main); err != nil {
		return didNotStart("Preparing the night worktree failed", err)
	}
	if err := steps.Preflight(); err != nil {
		return didNotStart("This job cannot drive the window", err)
	}
	r.First, err = steps.Suite(deadline)
	if err != nil {
		return didNotStart("The suite could not run", err)
	}
	r.Outcome = r.First.Outcome()
	switch {
	case r.Outcome == Green:
		if err := store.SetLastGreen(main); err != nil {
			r.Skipped = append(r.Skipped, "recording the green night failed: "+err.Error())
		}
		return r
	case r.Outcome == CutShort || len(r.First.Red) == 0:
		return r
	}
	fixAndRerun(steps, store, &r)
	return r
}

// fixAndRerun is the one fix round and the one re-run a red night gets.
func fixAndRerun(steps Steps, store Store, r *Result) {
	branch := "e2e-night/" + r.Night.Format(dateLayout)
	skip := func(why string, err error) {
		if err != nil {
			why += ": " + err.Error()
		}
		r.Skipped = append(r.Skipped, why)
	}
	if err := steps.Branch(branch, r.Main); err != nil {
		skip("the fix branch could not be made", err)
		return
	}
	unmerged, err := steps.Unmerged(r.Main)
	if err != nil {
		skip("listing earlier night branches failed", err)
	}
	in := FixInput{
		Branch: branch, Main: r.Main, Red: r.First.Red, CoverRed: r.First.CoverRed,
		Unmerged: unmerged, SummaryPath: store.FixerSummaryPath(r.Night),
		Deadline: Deadline(steps.Now()).Add(-RerunEstimate(len(r.First.Red))),
	}
	if err := steps.Fix(in); err != nil {
		skip("the fixer stopped with an error", err)
	}
	if body, err := os.ReadFile(in.SummaryPath); err == nil {
		r.Fixer = string(body)
	}
	commits, err := steps.Commits(r.Main)
	if err != nil {
		skip("listing the fix commits failed", err)
		return
	}
	if len(commits) == 0 {
		skip("the fixer committed nothing, so there was nothing to re-run", nil)
		if err := steps.DropBranch(branch); err != nil {
			skip("removing the empty fix branch failed", err)
		}
		return
	}
	r.Branch, r.FixCommits = branch, commits
	// Detach at the branch's tip: the re-run tests only what was committed, and
	// the branch is free for the operator to check out or delete.
	if err := steps.Prepare(branch); err != nil {
		skip("cleaning the worktree before the re-run failed", err)
		return
	}
	now := steps.Now()
	if now.Add(RerunEstimate(len(r.First.Red))).After(Deadline(now)) {
		skip("re-run skipped: it could not finish by 07:00", nil)
		return
	}
	files := make([]string, len(r.First.Red))
	for i, f := range r.First.Red {
		files[i] = f.File
	}
	rerun, err := steps.Rerun(files, Deadline(now))
	if err != nil {
		skip("the re-run could not run", err)
		return
	}
	r.Rerun = &rerun
}
