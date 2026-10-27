package night

import (
	"strings"
	"testing"
)

func TestACutShortRunIsNeverRed(t *testing.T) {
	run := SuiteRun{TimedOut: true, Red: []RedFile{{File: "e2e/checks/seeded/a.jsonl"}}}
	if got := run.Outcome(); got != CutShort {
		t.Fatalf("outcome %q, want %q", got, CutShort)
	}
}

func TestASuiteRunIsRedOnAFileOrOnCoverage(t *testing.T) {
	if got := (SuiteRun{Red: []RedFile{{File: "a"}}}).Outcome(); got != Red {
		t.Errorf("a red file: %q", got)
	}
	if got := (SuiteRun{CoverRed: "2 actions uncovered"}).Outcome(); got != Red {
		t.Errorf("coverage red: %q", got)
	}
	if got := (SuiteRun{}).Outcome(); got != Green {
		t.Errorf("nothing red: %q", got)
	}
}

func TestARedNightWithAFixSaysEverythingTheMorningNeeds(t *testing.T) {
	r := Result{
		Night:   at(27, 0, 0),
		Outcome: Red,
		Main:    "abc1234def",
		First: SuiteRun{Red: []RedFile{
			{File: "e2e/checks/seeded/a.jsonl", Note: "expected focus on x", Evidence: ".context/e2e/run-1"},
			{File: "e2e/checks/seeded/b.jsonl", Note: "frame not inside pane"},
		}},
		Branch:     "e2e-night/2026-10-27",
		FixCommits: []string{"f00d123 panes: keep focus"},
		Fixer:      "## Draft PR description\n\nFixes two checks.",
		Rerun:      &SuiteRun{},
	}
	md := r.Markdown()
	for _, want := range []string{
		"2026-10-27", "abc1234def",
		"e2e/checks/seeded/a.jsonl", "expected focus on x", ".context/e2e/run-1",
		"e2e/checks/seeded/b.jsonl", "frame not inside pane",
		"e2e-night/2026-10-27", "f00d123 panes: keep focus",
		"green after a night fix (f00d123)",
		"Draft PR description",
	} {
		if !strings.Contains(md, want) {
			t.Errorf("missing %q in:\n%s", want, md)
		}
	}
}

func TestANightThatDidNotStartNeverReadsAsGreen(t *testing.T) {
	md := Result{Night: at(27, 0, 0), Outcome: DidNotStart, Reason: "woke at 08:30, after 07:00"}.Markdown()
	if !strings.Contains(md, "did not start") || !strings.Contains(md, "after 07:00") {
		t.Fatalf("missing outcome or reason:\n%s", md)
	}
	if strings.Contains(strings.ToLower(md), "green") {
		t.Fatalf("a night that did not start mentions green:\n%s", md)
	}
}
