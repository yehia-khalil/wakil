package night

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// Outcome is what a night, or one run inside it, came to. A run that was cut
// short at 07:00 is neither green nor red: its records cover part of the suite.
type Outcome string

const (
	NotPending  Outcome = "not pending"
	DidNotStart Outcome = "did not start"
	Green       Outcome = "green"
	Red         Outcome = "red"
	CutShort    Outcome = "cut short"
)

// RedFile is one check file that went red, in the harness's own words.
type RedFile struct {
	File     string
	Note     string
	Fatal    []string
	Evidence string
}

// SuiteRun is what one pass over the checks left: the red files, the coverage
// gate's output when it was red, and whether 07:00 stopped it.
type SuiteRun struct {
	Red      []RedFile
	CoverRed string
	TimedOut bool
}

func (s SuiteRun) Outcome() Outcome {
	switch {
	case s.TimedOut:
		return CutShort
	case len(s.Red) > 0 || s.CoverRed != "":
		return Red
	}
	return Green
}

// Result is one night, as the morning reads it.
type Result struct {
	Night   time.Time
	Outcome Outcome
	// Reason says why a night did not start or was not pending.
	Reason string
	// Main is the origin/main commit the night ran.
	Main   string
	First  SuiteRun
	Branch string
	// FixCommits are the fix branch's commits, one "<short sha> <subject>" each.
	FixCommits []string
	// Fixer is what the fixer wrote: its summary and the drafted PR description.
	Fixer   string
	Rerun   *SuiteRun
	Skipped []string
}

// RedFilesSince reads the run records a pass left under evidenceRoot and
// returns the red ones written at or after since, by file.
func RedFilesSince(evidenceRoot string, since time.Time) ([]RedFile, error) {
	records, err := driver.ReadRunRecords(evidenceRoot)
	if err != nil {
		return nil, err
	}
	var red []RedFile
	for _, r := range records {
		if r.RanAt.Before(since) || r.Green() {
			continue
		}
		red = append(red, RedFile{File: r.File, Note: r.Note, Fatal: r.Fatal, Evidence: r.Evidence})
	}
	sort.Slice(red, func(i, j int) bool { return red[i].File < red[j].File })
	return red, nil
}

// Markdown renders the night for the morning.
func (r Result) Markdown() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# e2e night of %s: %s\n\n", r.Night.Format("2006-01-02"), r.Outcome)
	if r.Reason != "" {
		fmt.Fprintf(&b, "%s\n\n", r.Reason)
	}
	if r.Main != "" {
		fmt.Fprintf(&b, "Ran `make e2e-full` on origin/main at `%s`.\n\n", r.Main)
	}
	if r.Outcome != NotPending && r.Outcome != DidNotStart {
		writeRun(&b, "The full run", r.First)
	}
	if r.Branch != "" {
		fmt.Fprintf(&b, "## Fix branch `%s`\n\n", r.Branch)
		for _, c := range r.FixCommits {
			fmt.Fprintf(&b, "- %s\n", c)
		}
		b.WriteString("\nLocal only, not pushed.\n\n")
	}
	if r.Rerun != nil {
		if r.Rerun.Outcome() == Green && len(r.FixCommits) > 0 {
			sha, _, _ := strings.Cut(r.FixCommits[len(r.FixCommits)-1], " ")
			fmt.Fprintf(&b, "## The re-run: green after a night fix (%s)\n\nReview the fix before trusting it.\n\n", sha)
		} else {
			writeRun(&b, "The re-run", *r.Rerun)
		}
	}
	if len(r.Skipped) > 0 {
		b.WriteString("## Skipped\n\n")
		for _, s := range r.Skipped {
			fmt.Fprintf(&b, "- %s\n", s)
		}
		b.WriteString("\n")
	}
	if r.Fixer != "" {
		fmt.Fprintf(&b, "## What the fixer wrote\n\n%s\n", strings.TrimSpace(r.Fixer))
	}
	return b.String()
}

func writeRun(b *strings.Builder, title string, run SuiteRun) {
	fmt.Fprintf(b, "## %s: %s\n\n", title, run.Outcome())
	if run.TimedOut {
		b.WriteString("Stopped at 07:00; the records below cover only the files that ran.\n\n")
	}
	for _, f := range run.Red {
		fmt.Fprintf(b, "- `%s`: %s\n", f.File, f.Note)
		for _, fatal := range f.Fatal {
			fmt.Fprintf(b, "  - %s\n", fatal)
		}
		if f.Evidence != "" {
			fmt.Fprintf(b, "  - evidence: `%s`\n", f.Evidence)
		}
	}
	if run.CoverRed != "" {
		fmt.Fprintf(b, "\nThe coverage gate is red (reported, not fixed: writing checks is the auditor's job):\n\n```\n%s\n```\n", strings.TrimSpace(run.CoverRed))
	}
	b.WriteString("\n")
}
