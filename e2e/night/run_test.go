package night

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// fakeNight is a night whose steps record what was asked of them.
type fakeNight struct {
	now       time.Time
	quiet     bool
	main      string
	first     SuiteRun
	rerun     SuiteRun
	commits   []string
	unmerged  []string
	calls     []string
	fixIn     *FixInput
	rerunWith []string
	branch    string
	dropped   string
	docs      error
}

func (f *fakeNight) steps() Steps {
	return Steps{
		Now: func() time.Time { return f.now },
		ScreenQuiet: func(until time.Time) (bool, error) {
			f.calls = append(f.calls, "quiet")
			return f.quiet, nil
		},
		Fetch: func() (string, error) { f.calls = append(f.calls, "fetch"); return f.main, nil },
		MergeCheck: func() error {
			f.calls = append(f.calls, "merge-check")
			return f.docs
		},
		Preflight: func() error { return nil },
		Prepare: func(commit string) error {
			f.calls = append(f.calls, "prepare "+commit)
			return nil
		},
		Suite: func(deadline time.Time) (SuiteRun, error) {
			f.calls = append(f.calls, "suite")
			return f.first, nil
		},
		Branch: func(name, at string) error {
			f.calls = append(f.calls, "branch")
			f.branch = name + "@" + at
			return nil
		},
		Unmerged: func(main string) ([]string, error) { return f.unmerged, nil },
		Fix: func(in FixInput) error {
			f.calls = append(f.calls, "fix")
			f.fixIn = &in
			return os.WriteFile(in.SummaryPath, []byte("## Draft PR description\n\nfixed"), 0o644)
		},
		Commits: func(since string) ([]string, error) { return f.commits, nil },
		DropBranch: func(name string) error {
			f.calls = append(f.calls, "drop")
			f.dropped = name
			return nil
		},
		Rerun: func(files []string, deadline time.Time) (SuiteRun, error) {
			f.calls = append(f.calls, "rerun")
			f.rerunWith = files
			return f.rerun, nil
		},
	}
}

func (f *fakeNight) called(step string) bool {
	for _, c := range f.calls {
		if c == step || strings.HasPrefix(c, step+" ") {
			return true
		}
	}
	return false
}

func newFake(t *testing.T) (*fakeNight, Store) {
	t.Helper()
	store, err := OpenStore(gitRepo(t))
	if err != nil {
		t.Fatal(err)
	}
	return &fakeNight{now: at(27, 23, 0), quiet: true, main: "main2"}, store
}

func assertWritten(t *testing.T, store Store, r Result) {
	t.Helper()
	if _, err := os.Stat(store.ResultPath(r.Night)); err != nil {
		t.Fatalf("no result written: %v", err)
	}
}

var twoRed = SuiteRun{Red: []RedFile{
	{File: "e2e/checks/seeded/a.jsonl", Note: "a broke"},
	{File: "e2e/checks/seeded/b.jsonl", Note: "b broke"},
}}

func TestOutsideTheWindowNothingRuns(t *testing.T) {
	f, store := newFake(t)
	f.now = at(28, 8, 30)
	r := Run(f.steps(), store)
	if r.Outcome != DidNotStart || !strings.Contains(r.Reason, "07:00") || f.called("fetch") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	assertWritten(t, store, r)
}

func TestABusyScreenUntilTheDeadlineDoesNotStart(t *testing.T) {
	f, store := newFake(t)
	f.quiet = false
	r := Run(f.steps(), store)
	if r.Outcome != DidNotStart || f.called("suite") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	assertWritten(t, store, r)
}

func TestMainNotMovedIsNotPending(t *testing.T) {
	f, store := newFake(t)
	store.SetLastGreen("main2")
	r := Run(f.steps(), store)
	if r.Outcome != NotPending || f.called("prepare") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	assertWritten(t, store, r)
}

func TestAGreenNightMovesLastGreen(t *testing.T) {
	f, store := newFake(t)
	store.SetLastGreen("main1")
	r := Run(f.steps(), store)
	if got, _ := store.LastGreen(); r.Outcome != Green || got != "main2" || f.called("fix") {
		t.Fatalf("result %+v, last green %q, calls %v", r, got, f.calls)
	}
	assertWritten(t, store, r)
}

func TestARedNightFixesOnOneBranchAndRerunsOnlyTheRed(t *testing.T) {
	f, store := newFake(t)
	store.SetLastGreen("main1")
	f.first = twoRed
	f.unmerged = []string{"e2e-night/2026-10-25"}
	f.commits = []string{"f00d123 panes: keep focus"}
	r := Run(f.steps(), store)
	if f.branch != "e2e-night/2026-10-27@main2" {
		t.Fatalf("branch %q", f.branch)
	}
	if f.fixIn == nil || len(f.fixIn.Red) != 2 || f.fixIn.Unmerged[0] != "e2e-night/2026-10-25" ||
		f.fixIn.Branch != "e2e-night/2026-10-27" || f.fixIn.Main != "main2" {
		t.Fatalf("fix input %+v", f.fixIn)
	}
	if want := Deadline(f.now).Add(-RerunEstimate(2)); !f.fixIn.Deadline.Equal(want) {
		t.Fatalf("fixer deadline %s, want %s", f.fixIn.Deadline, want)
	}
	if strings.Join(f.rerunWith, " ") != "e2e/checks/seeded/a.jsonl e2e/checks/seeded/b.jsonl" {
		t.Fatalf("rerun with %v", f.rerunWith)
	}
	if got, _ := store.LastGreen(); r.Outcome != Red || r.Rerun == nil || got != "main1" {
		t.Fatalf("result %+v, last green %q", r, got)
	}
	if !strings.Contains(r.Fixer, "Draft PR description") {
		t.Fatalf("fixer summary not carried: %q", r.Fixer)
	}
	assertWritten(t, store, r)
}

func TestAFixerThatCommitsNothingIsNotRerun(t *testing.T) {
	f, store := newFake(t)
	f.first = twoRed
	r := Run(f.steps(), store)
	if f.called("rerun") || f.dropped != "e2e-night/2026-10-27" || r.Outcome != Red || r.Branch != "" {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	if !strings.Contains(strings.Join(r.Skipped, "\n"), "committed nothing") {
		t.Fatalf("skipped %v", r.Skipped)
	}
	assertWritten(t, store, r)
}

func TestARerunThatCannotFinishBy7IsSkipped(t *testing.T) {
	f, store := newFake(t)
	f.first = SuiteRun{Red: twoRed.Red[:1]}
	f.commits = []string{"f00d123 fix"}
	steps := f.steps()
	fix := steps.Fix
	steps.Fix = func(in FixInput) error { f.now = at(28, 6, 45); return fix(in) }
	r := Run(steps, store)
	if f.called("rerun") || !strings.Contains(strings.Join(r.Skipped, "\n"), "re-run skipped: it could not finish by 07:00") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	assertWritten(t, store, r)
}

func TestACutShortSuiteIsNeitherGreenNorRedAndIsNotFixed(t *testing.T) {
	f, store := newFake(t)
	store.SetLastGreen("main1")
	f.first = SuiteRun{TimedOut: true, Red: twoRed.Red}
	r := Run(f.steps(), store)
	if got, _ := store.LastGreen(); r.Outcome != CutShort || f.called("fix") || got != "main1" {
		t.Fatalf("result %+v, last green %q, calls %v", r, got, f.calls)
	}
	assertWritten(t, store, r)
}

func TestACoverageRedIsReportedNotFixed(t *testing.T) {
	f, store := newFake(t)
	f.first = SuiteRun{CoverRed: "2 actions carry no check"}
	r := Run(f.steps(), store)
	if r.Outcome != Red || f.called("fix") || !strings.Contains(r.Markdown(), "2 actions carry no check") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	assertWritten(t, store, r)
}

func TestAMissedNightIsFiledUnderTheNightItMissed(t *testing.T) {
	f, store := newFake(t)
	f.now = at(28, 8, 30)
	r := Run(f.steps(), store)
	if !r.Night.Equal(at(27, 0, 0)) {
		t.Fatalf("filed under %s, want the night of Oct 27", r.Night)
	}
	assertWritten(t, store, r)
}

func TestARunOutsideTheWindowNeverOverwritesARealNight(t *testing.T) {
	f, store := newFake(t)
	store.WriteResult(Result{Night: at(27, 0, 0), Outcome: Green, Main: "main2"})
	f.now = at(28, 8, 30)
	Run(f.steps(), store)
	if _, body, _ := store.Latest(); !strings.Contains(body, "green") {
		t.Fatalf("the real night was overwritten:\n%s", body)
	}
}

func TestASuiteThatCannotFinishBy7IsNotStarted(t *testing.T) {
	f, store := newFake(t)
	f.now = at(28, 6, 30)
	r := Run(f.steps(), store)
	if r.Outcome != DidNotStart || f.called("suite") || !strings.Contains(r.Reason, "07:00") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
}

func TestAJobWithoutAccessibilityDoesNotStart(t *testing.T) {
	f, store := newFake(t)
	steps := f.steps()
	steps.Preflight = func() error { return errNoAccessibility("/x/bin/wakil-e2e-night") }
	r := Run(steps, store)
	if r.Outcome != DidNotStart || f.called("suite") || !strings.Contains(r.Reason, "Accessibility") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
}

func TestTheFixBranchIsReleasedAndCleanedBeforeTheRerun(t *testing.T) {
	f, store := newFake(t)
	f.first = twoRed
	f.commits = []string{"f00d123 fix"}
	Run(f.steps(), store)
	got := strings.Join(f.calls, ",")
	if !strings.Contains(got, "fix,prepare e2e-night/2026-10-27,rerun") {
		t.Fatalf("calls %s: want the worktree detached and cleaned at the fix branch between fix and rerun", got)
	}
}

func TestFeatureDocsOnMainAreReportedAndTheSuiteStillRuns(t *testing.T) {
	f, store := newFake(t)
	f.docs = errors.New("docs/superpowers/specs/x.md")
	r := Run(f.steps(), store)
	if !strings.Contains(r.MergeCheck, "docs/superpowers/specs/x.md") || !f.called("suite") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
	assertWritten(t, store, r)
}

func TestCleanMainReportsNoFeatureDocs(t *testing.T) {
	f, store := newFake(t)
	r := Run(f.steps(), store)
	if r.MergeCheck != "" || !f.called("merge-check") {
		t.Fatalf("result %+v, calls %v", r, f.calls)
	}
}
