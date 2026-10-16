package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseChecksReadsOneStepPerNonEmptyLine(t *testing.T) {
	got, err := ParseChecks("org-plane", []byte(
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`+"\n"+
			`{"expect":{"tree":"contains","text":"NOTHING BEHIND THIS PLANE"}}`+"\n"))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if len(got.Steps) != 2 {
		t.Fatalf("got %d steps, want 2", len(got.Steps))
	}
	if got.Steps[0].Expect.Text != "ORGANISATION" {
		t.Fatalf("first step = %+v", got.Steps[0])
	}
}

// Blank lines are skipped and produce no step, so step N corresponds to the
// Nth non-empty line — the same contract `--dispatch` gives its scripts.
func TestParseChecksSkipsBlankLines(t *testing.T) {
	got, err := ParseChecks("x", []byte("\n  \n"+`{"expect":{"tree":"contains","text":"a"}}`+"\n\n"))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if len(got.Steps) != 1 {
		t.Fatalf("got %d steps, want 1", len(got.Steps))
	}
}

// A CRLF-saved file must not arrive as one enormous line: "\r\n" is a single
// Swift Character, and `--dispatch` records this exact trap in its doc comment.
func TestParseChecksHandlesCRLF(t *testing.T) {
	got, err := ParseChecks("x", []byte(
		`{"expect":{"tree":"contains","text":"a"}}`+"\r\n"+
			`{"expect":{"tree":"contains","text":"b"}}`+"\r\n"))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if len(got.Steps) != 2 {
		t.Fatalf("got %d steps, want 2", len(got.Steps))
	}
}

// A check file with no steps asserts nothing, and a check that asserts nothing
// passing is the failure this whole harness exists to prevent.
func TestParseChecksRejectsAFileWithNoSteps(t *testing.T) {
	if _, err := ParseChecks("empty", []byte("\n\n")); err == nil {
		t.Fatal("want an error for a check file with no steps")
	}
}

func TestParseChecksRejectsAnUnknownStepKind(t *testing.T) {
	_, err := ParseChecks("x", []byte(`{"teleport":{"to":"mars"}}`))
	if err == nil {
		t.Fatal("want an error for an unknown step kind")
	}
	if !strings.Contains(err.Error(), "x") {
		t.Fatalf("error must name the check, got %q", err)
	}
}

func TestParseChecksRejectsMalformedJSON(t *testing.T) {
	if _, err := ParseChecks("x", []byte(`{"expect":`)); err == nil {
		t.Fatal("want an error for malformed JSON")
	}
}

// `go test` reports a skipped test as ok, which is why `make test-live` had to
// grow a skip check: a live target with no engines running passed cleanly and
// certified nothing. A GUI runner has the same failure, so a run that executed
// no check at all must be red.
func TestResultRefusesARunThatExecutedNothing(t *testing.T) {
	if err := (Result{}).Err(); err == nil {
		t.Fatal("want an error when zero checks ran")
	}
}

func TestResultRefusesARunThatAssertedNothing(t *testing.T) {
	err := Result{ChecksRun: 3, Assertions: 0}.Err()
	if err == nil {
		t.Fatal("want an error when checks ran but asserted nothing")
	}
	if !strings.Contains(err.Error(), "asserted") {
		t.Fatalf("error must say what was missing, got %q", err)
	}
}

func TestResultReportsFailures(t *testing.T) {
	err := Result{ChecksRun: 1, Assertions: 2, Failures: []string{"org plane label absent"}}.Err()
	if err == nil {
		t.Fatal("want an error when a check failed")
	}
	if !strings.Contains(err.Error(), "org plane label absent") {
		t.Fatalf("error must carry the failure, got %q", err)
	}
}

func TestResultPassesWhenChecksRanAndAsserted(t *testing.T) {
	if err := (Result{ChecksRun: 1, Assertions: 1}).Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

// The reported line must be the line in the file, so an operator can go
// straight to it. Blank lines produce no step but still consume a number.
func TestParseChecksReportsTheFileLineNumber(t *testing.T) {
	_, err := ParseChecks("x", []byte(
		"\n"+ // line 1
			`{"expect":{"tree":"contains","text":"a"}}`+"\n"+ // line 2
			"\n"+ // line 3
			`{"expect":`+"\n")) // line 4, malformed
	if err == nil {
		t.Fatal("want an error")
	}
	if !strings.Contains(err.Error(), "line 4") {
		t.Fatalf("want the error to name line 4, got %q", err)
	}
}

// --- #251: the four step kinds -------------------------------------------

func TestParseChecksReadsADoClick(t *testing.T) {
	got, err := ParseChecks("x", []byte(`{"do":{"click":"landing.row.open:db"}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if got.Steps[0].Do == nil || got.Steps[0].Do.Click != "landing.row.open:db" {
		t.Fatalf("step = %+v", got.Steps[0])
	}
}

func TestParseChecksReadsADoType(t *testing.T) {
	got, err := ParseChecks("x", []byte(`{"do":{"type":{"into":"window.composer","text":"hello"}}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	typed := got.Steps[0].Do.Type
	if typed == nil || typed.Into != "window.composer" || typed.Text != "hello" {
		t.Fatalf("step = %+v", got.Steps[0].Do)
	}
}

func TestParseChecksReadsADispatch(t *testing.T) {
	got, err := ParseChecks("x", []byte(`{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if got.Steps[0].Dispatch == nil || got.Steps[0].Dispatch.Action != "pane_open" {
		t.Fatalf("step = %+v", got.Steps[0])
	}
	if got.Steps[0].Dispatch.Params["kind"] != "db" {
		t.Fatalf("params = %+v", got.Steps[0].Dispatch.Params)
	}
}

func TestParseChecksReadsAParity(t *testing.T) {
	got, err := ParseChecks("x", []byte(
		`{"parity":{"action":"pane_maximize","params":{"id":"db-1"},"click":"pane.db-1.maximize","assert":"read_layout"}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	parity := got.Steps[0].Parity
	if parity == nil || parity.Action != "pane_maximize" || parity.Click != "pane.db-1.maximize" {
		t.Fatalf("step = %+v", got.Steps[0])
	}
	if parity.Assert != "read_layout" {
		t.Fatalf("assert = %q", parity.Assert)
	}
}

func TestParseChecksReadsAnExpectPane(t *testing.T) {
	got, err := ParseChecks("x", []byte(`{"expect":{"pane":"db-1","field":"title","equals":"Left"}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	expect := got.Steps[0].Expect
	if expect.Pane != "db-1" || expect.Field != "title" || expect.Equals == nil || *expect.Equals != "Left" {
		t.Fatalf("step = %+v", expect)
	}
}

func TestParseChecksReadsAnExpectProcess(t *testing.T) {
	got, err := ParseChecks("x", []byte(`{"expect":{"process":{"none-matching":"tail -f"}}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if got.Steps[0].Expect.Process == nil || got.Steps[0].Expect.Process.NoneMatching != "tail -f" {
		t.Fatalf("step = %+v", got.Steps[0].Expect)
	}
}

func TestParseChecksReadsTreeAbsent(t *testing.T) {
	got, err := ParseChecks("x", []byte(`{"expect":{"tree":"absent","text":"Landing"}}`))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	if got.Steps[0].Expect.Tree != "absent" {
		t.Fatalf("step = %+v", got.Steps[0].Expect)
	}
}

// **Two kinds on one line is an error, never a silent precedence.** A line
// carrying both an act and an assertion would run one and drop the other, and
// which one ran would depend on field order in a struct the check author
// cannot see.
func TestParseChecksRejectsTwoKindsOnOneLine(t *testing.T) {
	_, err := ParseChecks("x", []byte(
		`{"do":{"click":"landing.row.open:db"},"expect":{"tree":"contains","text":"a"}}`))
	if err == nil {
		t.Fatal("want an error when one line carries two step kinds")
	}
	if !strings.Contains(err.Error(), "one step kind") {
		t.Fatalf("error must say what is wrong, got %q", err)
	}
}

func TestParseChecksRejectsADoWithBothClickAndType(t *testing.T) {
	_, err := ParseChecks("x", []byte(
		`{"do":{"click":"landing.row.open:db","type":{"into":"window.composer","text":"a"}}}`))
	if err == nil {
		t.Fatal("want an error when a do carries both a click and a type")
	}
}

func TestParseChecksRejectsAnEmptyDo(t *testing.T) {
	if _, err := ParseChecks("x", []byte(`{"do":{}}`)); err == nil {
		t.Fatal("want an error for a do that does nothing")
	}
}

func TestParseChecksRejectsADispatchWithNoAction(t *testing.T) {
	if _, err := ParseChecks("x", []byte(`{"dispatch":{"params":{"kind":"db"}}}`)); err == nil {
		t.Fatal("want an error for a dispatch naming no action")
	}
}

// A parity step with no click cannot compare two channels, and a parity step
// that silently degraded to a single dispatch would assert Invariant 2 holds
// while never testing the UI path at all.
func TestParseChecksRejectsAParityWithNoClick(t *testing.T) {
	_, err := ParseChecks("x", []byte(`{"parity":{"action":"pane_maximize","assert":"read_layout"}}`))
	if err == nil {
		t.Fatal("want an error for a parity step with no click")
	}
	if !strings.Contains(err.Error(), "click") {
		t.Fatalf("error must name what is missing, got %q", err)
	}
}

func TestParseChecksRejectsAnUnknownParityAssert(t *testing.T) {
	_, err := ParseChecks("x", []byte(
		`{"parity":{"action":"pane_maximize","click":"pane.db-1.maximize","assert":"vibes"}}`))
	if err == nil {
		t.Fatal("want an error for an unknown parity assertion")
	}
}

func TestParseChecksRejectsAnExpectWithNoArm(t *testing.T) {
	if _, err := ParseChecks("x", []byte(`{"expect":{}}`)); err == nil {
		t.Fatal("want an error for an expect that asserts nothing")
	}
}

func TestParseChecksRejectsAnExpectPaneWithNoEquals(t *testing.T) {
	if _, err := ParseChecks("x", []byte(`{"expect":{"pane":"db-1","field":"title"}}`)); err == nil {
		t.Fatal("want an error for an expect naming a field but no expected value")
	}
}

// An identifier outside the registered surfaces cannot resolve, and finding
// that out at parse time names the typo instead of failing mid-run against a
// live window.
func TestParseChecksRejectsAClickOutsideTheRegisteredSurfaces(t *testing.T) {
	_, err := ParseChecks("x", []byte(`{"do":{"click":"teleporter.row.mars"}}`))
	if err == nil {
		t.Fatal("want an error for an identifier in no registered surface")
	}
	if !strings.Contains(err.Error(), "surface") {
		t.Fatalf("error must say why, got %q", err)
	}
}

// LoadChecks is the command's entry into ParseChecks, and it moved here from
// `wakil-e2e`'s own main when `make e2e-new` became a second caller. **A run
// named with no check files is refused**, because a run that loads nothing
// executes nothing and exits 0.
func TestLoadChecksRefusesARunThatNamesNoFiles(t *testing.T) {
	if _, err := LoadChecks(nil); err == nil {
		t.Fatal("want a refusal: no check files were named, so nothing would be proved")
	}
}

// A check is named by its file's base name, which is what --quarantine and
// the verdict record both address it by.
func TestLoadChecksNamesEachCheckAfterItsFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "landing.jsonl")
	if err := os.WriteFile(path, []byte(`{"expect":{"tree":"contains","text":"x"}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	checks, err := LoadChecks([]string{path})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(checks) != 1 || checks[0].Name != "landing.jsonl" {
		t.Fatalf("got %v", checks)
	}
}

// A path that is not there fails the load rather than being skipped. A glob
// that matched nothing expands to itself, so a silent skip would turn a typo
// in a Makefile into a run that proved nothing and said it passed.
func TestLoadChecksRefusesAPathThatIsNotThere(t *testing.T) {
	_, err := LoadChecks([]string{filepath.Join(t.TempDir(), "absent.jsonl")})
	if err == nil {
		t.Fatal("want a refusal for a check file that does not exist")
	}
	if !strings.Contains(err.Error(), "absent.jsonl") {
		t.Fatalf("the refusal must name the path, got %q", err)
	}
}

// **A text field cannot be focused by pressing it.** Measured 2026-09-24:
// AXPress on `window.composer` returns AXError -25206 (action unsupported),
// and setting its value does not move keyboard focus — so the agent composer,
// which has no `@FocusState` of its own, was unreachable by any step this
// vocabulary had. `focus` is a real click at the element's own centre, which
// is what a mouse does.
func TestAFocusStepNamesTheControlItClicks(t *testing.T) {
	checks, err := ParseChecks("focus.jsonl", []byte(
		`{"do":{"focus":"window.composer"}}`+"\n"+
			`{"expect":{"tree":"contains","text":"x"}}`+"\n"))
	if err != nil {
		t.Fatalf("parsing: %v", err)
	}
	if got := checks.Steps[0].Do.Focus; got != "window.composer" {
		t.Fatalf("want the identifier carried, got %q", got)
	}
}

func TestAFocusStepWithNoIdentifierIsRefused(t *testing.T) {
	if _, err := ParseChecks("focus.jsonl", []byte(`{"do":{"focus":""}}`+"\n")); err == nil {
		t.Fatal("a focus step that names nothing would click at an unknown place")
	}
}

// A `do` step may drive exactly one arm, and `focus` joins the rule rather
// than sitting outside it.
func TestAFocusStepCannotAlsoClick(t *testing.T) {
	_, err := ParseChecks("focus.jsonl", []byte(
		`{"do":{"focus":"window.composer","click":"window.send"}}`+"\n"))
	if err == nil {
		t.Fatal("two arms in one step leave the order between them unstated")
	}
}

// TestAParityMayNameItsPaneEitherWay. The registry has two spellings —
// `pane_focus` names a pane `id`, `db_run_query` and every `api_*` action
// name it `pane` — and this read used to accept only the first. That made
// a `read_pane` parity impossible for half the registry, and the excluded
// half is the half that WRITES into panes, which is what Invariant 2's
// parity exists to compare.
func TestAParityMayNameItsPaneEitherWay(t *testing.T) {
	if got := ParityPaneID(map[string]interface{}{"id": "terminal-1"}); got != "terminal-1" {
		t.Errorf("id: got %q", got)
	}
	if got := ParityPaneID(map[string]interface{}{"pane": "api-1"}); got != "api-1" {
		t.Errorf("pane: got %q", got)
	}
	// Named neither way is the refusal ParseChecks turns into a parse
	// error, rather than a failure minutes into a live run.
	if got := ParityPaneID(map[string]interface{}{"statement": "x"}); got != "" {
		t.Errorf("neither: got %q", got)
	}
	// Empty is not named.
	if got := ParityPaneID(map[string]interface{}{"pane": ""}); got != "" {
		t.Errorf("empty: got %q", got)
	}
}

// TestAReadPaneParityNamingNoPaneIsRefusedAtParseTime. The whole point of
// the check: a step that names no pane parses cleanly and dies against a
// live window, minutes in, with a fixture instance on the screen.
func TestAReadPaneParityNamingNoPaneIsRefusedAtParseTime(t *testing.T) {
	line := `{"parity":{"action":"api_send","params":{"statement":"x"},` +
		`"click":"api.send","assert":"read_pane"}}`
	if _, err := ParseChecks("t.jsonl", []byte(line)); err == nil {
		t.Fatal("want a refusal for a read_pane parity naming no pane")
	}
	named := `{"parity":{"action":"api_send","params":{"pane":"api-1"},` +
		`"click":"api.send","assert":"read_pane"}}`
	if _, err := ParseChecks("t.jsonl", []byte(named)); err != nil {
		t.Fatalf("a parity naming its pane as `pane` was refused: %v", err)
	}
}

// --- Task 7: the drag arm ---------------------------------------------------
//
// **The source here is a stand-in, `pane.db-1.grip`, not the grip's real
// `db.row.0.grip`.** `db` is not a registered surface yet: the identifiers
// file's rule is that a surface joins in the change that first names one of
// its controls, and that is Task 8, which draws the grip. Parse-time
// validation refuses an unregistered first segment, so the real name cannot
// parse until then — see TestADragFromAnUnregisteredSurfaceIsRefused.

func TestADoDragParses(t *testing.T) {
	check, err := ParseChecks("drag.jsonl", []byte(
		`{"do":{"drag":{"from":"pane.db-1.grip","to":"api.pane"}}}`+"\n"+
			`{"expect":{"tree":"contains","text":"x"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := check.Steps[0].Do.Describe(); got != "drag pane.db-1.grip onto api.pane" {
		t.Fatalf("Describe = %q", got)
	}
}

func TestADragWithNoTargetIsRefused(t *testing.T) {
	_, err := ParseChecks("drag.jsonl", []byte(`{"do":{"drag":{"from":"pane.db-1.grip"}}}`))
	if err == nil || !strings.Contains(err.Error(), "drag") {
		t.Fatalf("err = %v", err)
	}
}

func TestADragWithNoSourceIsRefused(t *testing.T) {
	_, err := ParseChecks("drag.jsonl", []byte(`{"do":{"drag":{"to":"api.pane"}}}`))
	if err == nil || !strings.Contains(err.Error(), "drag") {
		t.Fatalf("err = %v", err)
	}
}

func TestADragFromAnUnregisteredSurfaceIsRefused(t *testing.T) {
	_, err := ParseChecks("drag.jsonl", []byte(`{"do":{"drag":{"from":"teleporter.x","to":"api.pane"}}}`))
	if err == nil || !strings.Contains(err.Error(), "teleporter") {
		t.Fatalf("err = %v", err)
	}
	_, err = ParseChecks("drag.jsonl", []byte(`{"do":{"drag":{"from":"api.pane","to":"teleporter.x"}}}`))
	if err == nil || !strings.Contains(err.Error(), "teleporter") {
		t.Fatalf("err = %v", err)
	}
}

// A drag is one of the do arms and joins the exactly-one rule.
func TestADragCannotAlsoClick(t *testing.T) {
	_, err := ParseChecks("drag.jsonl", []byte(
		`{"do":{"click":"window.send","drag":{"from":"pane.db-1.grip","to":"api.pane"}}}`))
	if err == nil || !strings.Contains(err.Error(), "drag") {
		t.Fatalf("err = %v", err)
	}
}

func TestAParityCarriesExactlyOneOfClickAndDrag(t *testing.T) {
	_, err := ParseChecks("drag.jsonl", []byte(
		`{"parity":{"action":"api_bind","click":"window.send","drag":{"from":"pane.db-1.grip","to":"api.pane"},"assert":"tree"}}`))
	if err == nil {
		t.Fatal("a parity with both a click and a drag was accepted")
	}
}

func TestADragParityParses(t *testing.T) {
	check, err := ParseChecks("drag.jsonl", []byte(
		`{"parity":{"action":"api_bind","params":{"pane":"api-1"},"drag":{"from":"pane.db-1.grip","to":"api.pane"},"assert":"read_pane"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := check.Steps[0].Parity.Drag; got == nil || got.From != "pane.db-1.grip" || got.To != "api.pane" {
		t.Fatalf("drag = %+v", got)
	}
}

func TestADragParityWithAHalfDragIsRefused(t *testing.T) {
	_, err := ParseChecks("drag.jsonl", []byte(
		`{"parity":{"action":"api_bind","params":{"pane":"api-1"},"drag":{"from":"pane.db-1.grip"},"assert":"read_pane"}}`))
	if err == nil || !strings.Contains(err.Error(), "drag") {
		t.Fatalf("err = %v", err)
	}
}

func TestParseChecksReadsADispatchRefuses(t *testing.T) {
	got, err := ParseChecks("r", []byte(`{"dispatch":{"action":"x","refuses":"y"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got.Steps[0].Dispatch.Refuses != "y" {
		t.Fatalf("Refuses = %q", got.Steps[0].Dispatch.Refuses)
	}
	for _, line := range []string{`{"dispatch":{"action":"x","refuses":""}}`, `{"dispatch":{"action":"x"}}`} {
		got, err := ParseChecks("r", []byte(line))
		if err != nil {
			t.Fatal(err)
		}
		if got.Steps[0].Dispatch.Refuses != "" {
			t.Fatalf("%s: Refuses = %q", line, got.Steps[0].Dispatch.Refuses)
		}
	}
}
