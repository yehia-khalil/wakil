package driver_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func TestAnActionNoCheckDispatchesIsAGap(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "c.jsonl", `{"dispatch":{"action":"term_open"}}`))
	gaps := driver.Gaps(driver.Surface{Actions: []driver.Tool{
		{Name: "term_open", ReadOnly: true},
		{Name: "term_scroll", ReadOnly: true},
	}}, cover)

	if len(gaps) != 1 {
		t.Fatalf("gaps are %v, want term_scroll alone", gaps)
	}
	if gaps[0].Name != "term_scroll" || gaps[0].Rule != driver.RuleDispatched {
		t.Errorf("got %+v", gaps[0])
	}
}

// **Invariant 2, mechanised.** An action that changes anything has two ways in
// — a control and the socket — and the gate's job is to refuse a branch that
// wires the second without proving it agrees with the first.
func TestAWriteActionOwesAParityCheckAndAReadDoesNot(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "c.jsonl", `
{"dispatch":{"action":"pane_maximize"}}
{"dispatch":{"action":"read_layout"}}
`))
	gaps := driver.Gaps(driver.Surface{Actions: []driver.Tool{
		{Name: "pane_maximize", ReadOnly: false},
		{Name: "read_layout", ReadOnly: true},
	}}, cover)

	if len(gaps) != 1 {
		t.Fatalf("gaps are %v, want the parity of pane_maximize alone", gaps)
	}
	if gaps[0].Name != "pane_maximize" || gaps[0].Rule != driver.RuleParity {
		t.Errorf("got %+v", gaps[0])
	}
}

// An action that nothing drives at all is one piece of work, not two. Naming
// the parity it also lacks would report the same missing check twice and read
// as twice the backlog.
func TestAWriteActionNothingDrivesIsReportedOnce(t *testing.T) {
	gaps := driver.Gaps(driver.Surface{Actions: []driver.Tool{{Name: "db_run_mutation"}}},
		driver.CoverageOf(parse(t, "c.jsonl", `{"dispatch":{"action":"term_open"}}`)))
	if len(gaps) != 1 || gaps[0].Rule != driver.RuleDispatched {
		t.Fatalf("got %+v", gaps)
	}
}

func TestAnIdentifierNoCheckPressesIsAGap(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "c.jsonl", `{"do":{"click":"rail.terminal-1"}}`))
	gaps := driver.Gaps(driver.Surface{Identifiers: []driver.Identifier{
		{Name: "rail.<…>", File: "Rail.swift", Line: 12},
		{Name: "window.newTerminal", File: "WakilWindow.swift", Line: 40},
	}}, cover)

	if len(gaps) != 1 {
		t.Fatalf("gaps are %v, want window.newTerminal alone", gaps)
	}
	if gaps[0].Name != "window.newTerminal" || gaps[0].Rule != driver.RuleExercised {
		t.Errorf("got %+v", gaps[0])
	}
	// The report has to send a reader to the control, not only name it.
	if !strings.Contains(gaps[0].String(), "WakilWindow.swift:40") {
		t.Errorf("the gap does not say where the control is: %q", gaps[0])
	}
}

// **An exemption is a redirect with a reason, never a silent pass.** It is
// dropped from the gate's failures and returned as excused, so the caller
// prints it on every run — the rule quarantine and backfill already hold to,
// because a list nobody is reminded of is a list that grows.
func TestAnExemptionExcusesAGapAndKeepsItVisible(t *testing.T) {
	gaps := []driver.Gap{
		{Kind: driver.GapControl, Name: "window.quit", Rule: driver.RuleExercised},
		{Kind: driver.GapAction, Name: "term_close", Rule: driver.RuleDispatched},
	}
	remaining, excused := driver.Excuse(gaps, map[string]string{
		"window.quit": "quitting the fixture ends the run that would assert it",
	})
	if len(remaining) != 1 || remaining[0].Name != "term_close" {
		t.Fatalf("remaining gaps are %v", remaining)
	}
	if len(excused) != 1 || excused[0].Reason == "" {
		t.Fatalf("the excused gap lost its reason: %+v", excused)
	}
}

func TestAnExemptionWithoutAReasonIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "exempt.tsv")
	if err := os.WriteFile(path, []byte("window.quit\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := driver.LoadExemptions(path); err == nil {
		t.Fatal("an exemption naming no reason was accepted")
	}
}

func TestAMissingExemptionFileIsNotAnError(t *testing.T) {
	entries, err := driver.LoadExemptions(filepath.Join(t.TempDir(), "none.tsv"))
	if err != nil {
		t.Fatalf("a branch with no exemptions was refused: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("read %v out of a file that is not there", entries)
	}
}

// **The gate judges the new surface and reports against the whole.** Only
// newly added surface fails — pre-existing surface is the discovery audit's
// backlog — and the counts a run prints are of everything, because a gate that
// only ever printed what it failed on would let coverage of the whole registry
// fall without anything saying so.
func TestTheGateFailsOnNewSurfaceOnlyAndStillCountsTheWhole(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "c.jsonl", `{"dispatch":{"action":"term_open"}}`))
	all := driver.Surface{Actions: []driver.Tool{
		{Name: "term_open", ReadOnly: true},
		{Name: "db_page", ReadOnly: true},     // old, uncovered: backlog
		{Name: "term_scroll", ReadOnly: true}, // new, uncovered: red
	}}
	fresh := driver.Surface{Actions: []driver.Tool{{Name: "term_scroll", ReadOnly: true}}}

	report := driver.Judge(all, fresh, cover, nil)
	if err := report.Err(); err == nil {
		t.Fatal("new uncovered surface did not fail the gate")
	} else if !strings.Contains(err.Error(), "term_scroll") {
		t.Errorf("the failure does not name the new action: %v", err)
	}
	if strings.Contains(report.Err().Error(), "db_page") {
		t.Error("surface that predates the branch was failed on")
	}
	if got := report.Backlog(); len(got) != 2 {
		t.Errorf("the backlog is %v, want both uncovered actions", got)
	}
}

func TestAGateWithNothingNewPasses(t *testing.T) {
	report := driver.Judge(
		driver.Surface{Actions: []driver.Tool{{Name: "db_page", ReadOnly: true}}},
		driver.Surface{},
		driver.CoverageOf(parse(t, "c.jsonl", `{"dispatch":{"action":"term_open"}}`)),
		nil)
	if err := report.Err(); err != nil {
		t.Fatalf("a branch that added no surface failed the gate: %v", err)
	}
}

// The file in this repository, read as the gate reads it. It is nearly always
// empty of entries; what this proves is that an entry somebody adds in a hurry
// is refused by `make test` rather than silently by the gate on a GUI machine.
func TestTheRepositorysUncoverableListParses(t *testing.T) {
	entries, err := driver.LoadExemptions(filepath.Join("..", "..", driver.ExemptionFile))
	if err != nil {
		t.Fatal(err)
	}
	for name, reason := range entries {
		if strings.TrimSpace(reason) == "" {
			t.Errorf("%s is excused by nothing", name)
		}
	}
}

// **The corpus in this repository covers something.** Every guard above is
// about a coverage computation that is wrong; this one is about a coverage
// computation that silently stops reading steps at all — after which the gate
// reports the entire app as uncovered, the backlog becomes an inventory of
// everything, and both read as a repository with no checks in it.
func TestTheRepositorysChecksCoverSomething(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join("..", "checks", "*", "*.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no check files at all")
	}
	checks, err := driver.LoadChecks(paths)
	if err != nil {
		t.Fatal(err)
	}
	cover := driver.CoverageOf(checks)
	if len(cover.Dispatched()) == 0 {
		t.Error("the corpus dispatches no action at all")
	}
	if len(cover.Exercised()) == 0 {
		t.Error("the corpus presses no control at all")
	}
}

// **An entry that excuses nothing is a failure, not a no-op.** Quarantine is
// already held to this — a stale name there is Fatal — for the reason that
// applies here twice over: an exemption outlives the gap it was written for,
// nobody is ever prompted to delete it, and the file quietly becomes a list of
// surface nobody has to check any more.
func TestAnExemptionThatExcusesNothingFailsTheGate(t *testing.T) {
	report := driver.Judge(
		driver.Surface{Actions: []driver.Tool{{Name: "term_open", ReadOnly: true}}},
		driver.Surface{},
		driver.CoverageOf(parse(t, "c.jsonl", `{"dispatch":{"action":"term_open"}}`)),
		map[string]string{"term_open": "covered since last week, so this line is dead"})

	err := report.Err()
	if err == nil {
		t.Fatal("an exemption naming covered surface was accepted")
	}
	if !strings.Contains(err.Error(), "term_open") {
		t.Errorf("the failure does not name the dead entry: %v", err)
	}
}

// The backlog is what is still owed, so surface excused with a reason is not
// in it — it is printed as excused instead, every run, which is where a
// reviewer reads the reason.
func TestTheBacklogLeavesOutWhatIsExcused(t *testing.T) {
	report := driver.Judge(
		driver.Surface{Actions: []driver.Tool{
			{Name: "approve_tool_use", ReadOnly: true},
			{Name: "db_page", ReadOnly: true},
		}},
		driver.Surface{},
		driver.CoverageOf(parse(t, "c.jsonl", `{"dispatch":{"action":"term_open"}}`)),
		map[string]string{"approve_tool_use": "the CLI calls it; calling it from a check does nothing"})

	backlog := report.Backlog()
	if len(backlog) != 1 || backlog[0].Name != "db_page" {
		t.Fatalf("the backlog is %v, want db_page alone", backlog)
	}
	if len(report.Excused) != 1 || report.Excused[0].Reason == "" {
		t.Fatalf("the excused entry is not reported with its reason: %+v", report.Excused)
	}
	if err := report.Err(); err != nil {
		t.Errorf("an exemption covering a real gap failed the gate: %v", err)
	}
}
