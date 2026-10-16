package driver_test

import (
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// The four step kinds, and what each one contributes to coverage. A parity
// step contributes to both denominators at once, which is the whole reason
// the vocabulary has it.
func TestCoverageReadsEveryStepKind(t *testing.T) {
	checks := parse(t, "cover.jsonl", `
{"do":{"click":"rail.terminal-1"}}
{"do":{"type":{"into":"pane.db-1.query","text":"select 1"}}}
{"dispatch":{"action":"term_open"}}
{"parity":{"action":"pane_maximize","click":"pane.db-1.maximize","assert":"read_layout"}}
{"expect":{"pane":"db-1","field":"kind","equals":"db"}}
`)
	cover := driver.CoverageOf(checks)

	for _, action := range []string{"term_open", "pane_maximize"} {
		if !cover.Dispatches(action) {
			t.Errorf("%s is not counted as dispatched", action)
		}
	}
	if !cover.HasParity("pane_maximize") {
		t.Error("a parity step did not record parity for its own action")
	}
	if cover.HasParity("term_open") {
		t.Error("a plain dispatch was counted as parity, which would excuse an action from Invariant 2")
	}
	for _, identifier := range []string{"rail.terminal-1", "pane.db-1.query", "pane.db-1.maximize"} {
		if !cover.Exercises(identifier) {
			t.Errorf("%s is not counted as exercised", identifier)
		}
	}
}

// **A read through the socket is a dispatch, because it is one.** An
// `expect.pane` sends `read_pane` over the same channel a `dispatch` uses, and
// a coverage report that did not say so would list the two most-exercised
// tools in the harness as touched by nothing.
func TestCoverageCountsTheReadsAnAssertionMakes(t *testing.T) {
	checks := parse(t, "reads.jsonl", `
{"expect":{"pane":"db-1","field":"kind","equals":"db"}}
{"parity":{"action":"pane_select_cell","params":{"id":"db-1"},"click":"pane.db-1.cell","assert":"read_pane"}}
{"parity":{"action":"pane_move","click":"pane.db-1.title","assert":"read_layout"}}
`)
	cover := driver.CoverageOf(checks)
	for _, tool := range []string{"read_pane", "read_layout"} {
		if !cover.Dispatches(tool) {
			t.Errorf("%s is read by these checks and is not counted as dispatched", tool)
		}
	}
	// It is a read, not a proof of parity: nothing here drives `read_pane`
	// down two channels.
	if cover.HasParity("read_pane") {
		t.Error("an assertion's own read was counted as a parity check of that read")
	}
}

// A `tree` assertion names text rather than an identifier, and counting its
// text as a control would credit coverage to a string nobody can click.
func TestCoverageDoesNotCountATreeAssertionAsAControl(t *testing.T) {
	checks := parse(t, "tree.jsonl", `{"expect":{"tree":"contains","text":"rail.terminal-1"}}`)
	if cover := driver.CoverageOf(checks); cover.Exercises("rail.terminal-1") {
		t.Error("text asserted against the tree was counted as a control that was exercised")
	}
}

// **A dynamic identifier is a family, and a check exercises a member of it.**
// The harvester can only ever report `pane.<…>.reopen`; no check can address
// that, and every check addresses a concrete id instead. A gate that compared
// the two as strings would report every dynamic control uncovered forever,
// which is the shape of a gate that gets switched off.
func TestCoverageMatchesADynamicIdentifierAgainstAConcreteOne(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "dyn.jsonl", `
{"do":{"click":"pane.db-1.reopen"}}
{"do":{"click":"rail.terminal-2"}}
`))
	for _, family := range []string{"pane.<…>.reopen", "rail.<…>"} {
		if !cover.Exercises(family) {
			t.Errorf("%s is not matched by the concrete identifier a check clicks", family)
		}
	}
	for _, family := range []string{"pane.<…>.close", "window.<…>"} {
		if cover.Exercises(family) {
			t.Errorf("%s was matched by a check that clicks nothing of the sort", family)
		}
	}
}

// A placeholder stands for one segment's worth of name and never for a dot.
// `pane.<…>` matching `pane.db-1.reopen` would credit the family with every
// control under it.
func TestADynamicIdentifierNeverMatchesAcrossASegment(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "seg.jsonl", `{"do":{"click":"pane.db-1.reopen"}}`))
	if cover.Exercises("pane.<…>") {
		t.Error("a one-segment family matched a two-segment identifier")
	}
}

// A placeholder can be part of a segment — `"rail.\(pane.id)-row"` harvests as
// `rail.<…>-row` — and the literal text around it still has to match.
func TestAPlaceholderInsideASegmentKeepsTheTextAroundIt(t *testing.T) {
	cover := driver.CoverageOf(parse(t, "part.jsonl", `{"do":{"click":"rail.db-1-row"}}`))
	if !cover.Exercises("rail.<…>-row") {
		t.Error("rail.<…>-row is not matched by rail.db-1-row")
	}
	if cover.Exercises("rail.<…>-header") {
		t.Error("rail.<…>-header was matched by rail.db-1-row")
	}
}

// parse builds checks the way the runner does, so a test can never assert
// against a step shape the vocabulary would refuse.
func parse(t *testing.T, name, body string) []driver.Check {
	t.Helper()
	check, err := driver.ParseChecks(name, []byte(body))
	if err != nil {
		t.Fatalf("parsing %s: %v", name, err)
	}
	return []driver.Check{check}
}

// A focused control is an exercised control: the click is real, it lands on
// that element, and a gate that ignored it would ask for a second check
// covering a control a check already presses.
func TestFocusingAControlExercisesIt(t *testing.T) {
	cover := driver.CoverageOf([]driver.Check{{Name: "focus.jsonl", Steps: []driver.Step{
		{Do: &driver.Do{Focus: "window.composer"}},
	}}})
	if !cover.Exercises("window.composer") {
		t.Fatal("the focus click presses that control, so it is exercised")
	}
}

// A drag parity is a parity, and it exercises both ends: the grip the
// operator's hand is on, and the target the drop lands on, which is resolved
// by its identifier and receives a real drop (Ruling 10).
func TestADragParityCountsAsParityAndExercisesBothEnds(t *testing.T) {
	checks := parse(t, "drag.jsonl",
		`{"parity":{"action":"api_bind","params":{"pane":"api-1"},"drag":{"from":"db.row.0.grip","to":"api.pane"},"assert":"read_pane"}}`)
	cover := driver.CoverageOf(checks)
	if !cover.HasParity("api_bind") || !cover.Exercises("db.row.0.grip") {
		t.Fatal("a drag parity did not count")
	}
	if !cover.Exercises("api.pane") {
		t.Fatal("the drop target receives the drop, so it is exercised")
	}
	if cover.Exercises("") {
		t.Fatal("a drag parity has no click, and the empty name was counted as exercised")
	}
}

func TestADoDragExercisesBothEnds(t *testing.T) {
	cover := driver.CoverageOf([]driver.Check{{Name: "drag.jsonl", Steps: []driver.Step{
		{Do: &driver.Do{Drag: &driver.DragStep{From: "db.row.0.grip", To: "api.pane"}}},
	}}})
	if !cover.Exercises("db.row.0.grip") {
		t.Fatal("the grip a drag starts from is exercised")
	}
	if !cover.Exercises("api.pane") {
		t.Fatal("the target a drag drops on is exercised")
	}
}
