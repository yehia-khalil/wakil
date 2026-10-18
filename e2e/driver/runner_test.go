package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeChannel stands in for the live MCP socket.
type fakeChannel struct {
	calls   []string
	results map[string]string
	errs    map[string]error
}

func (f *fakeChannel) Call(action string, arguments map[string]interface{}) (ToolResult, error) {
	encoded, _ := json.Marshal(arguments)
	f.calls = append(f.calls, action+" "+string(encoded))
	if err, bad := f.errs[action]; bad {
		return ToolResult{}, err
	}
	body, known := f.results[action]
	if !known {
		body = "{}"
	}
	return ToolResult{Text: body, Structured: json.RawMessage(body)}, nil
}

type fakeProcesses struct {
	matches map[string][]string
	err     error
}

func (f fakeProcesses) Matching(pattern string) ([]string, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.matches[pattern], nil
}

func newRunner(t *testing.T, orcaBody string, channel *fakeChannel) (*Runner, string) {
	t.Helper()
	exe, _ := fakeOrca(t, orcaBody, 0)
	dir := t.TempDir()
	if channel == nil {
		channel = &fakeChannel{}
	}
	return &Runner{
		Orca:      Orca{Exe: exe},
		Resolver:  Resolver{Exe: fakeResolver(t)},
		Channel:   channel,
		PID:       44187,
		Processes: fakeProcesses{},
		Evidence:  &Evidence{Dir: dir},
	}, dir
}

// fakeResolver stands in for axresolve, reporting one named element and — when
// asked to act — the same `acted` block the real one reports.
//
// A press is unverified, because AX reports no outcome for one; a set-value is
// verified, because the resolver reads the value back before saying so. Those
// two facts are what the runner's confirmation rule is written against, so the
// stand-in has to carry them or the tests prove nothing about it.
func fakeResolver(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "axresolve")
	base := `{"ok":true,"window":{"x":0,"y":50,"width":1710,"height":1050},` +
		`"elements":[{"identifier":"landing.row.open:db","role":"button","enabled":true,` +
		`"x":100,"y":200,"width":120,"height":30}]`
	pressed := base + `,"acted":{"action":"press","identifier":"x","verified":false,` +
		`"reason":"accessibility_action_unasserted"}}`
	set := base + `,"acted":{"action":"set-value","identifier":"x","verified":true}}`
	dragged := base + `,"acted":{"action":"drag","identifier":"x","verified":false,` +
		`"reason":"synthetic_input"}}`
	script := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"  *--drag-to*) cat <<'DRAGGED'\n" + dragged + "\nDRAGGED\n;;\n" +
		"  *--press*) cat <<'PRESSED'\n" + pressed + "\nPRESSED\n;;\n" +
		"  *--set-value*) cat <<'SET'\n" + set + "\nSET\n;;\n" +
		"  *) cat <<'READ'\n" + base + "}\nREAD\n;;\n" +
		"esac\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

func mustParse(t *testing.T, name string, lines ...string) Check {
	t.Helper()
	got, err := ParseChecks(name, []byte(strings.Join(lines, "\n")+"\n"))
	if err != nil {
		t.Fatalf("ParseChecks: %v", err)
	}
	return got
}

// --- acts are not assertions ---------------------------------------------

// A check made only of acts proves nothing, and must be red rather than a
// quiet pass. This is the arm run.go's own doc comment said #251 would arm.
func TestRunnerRefusesACheckOfActsAlone(t *testing.T) {
	runner, _ := newRunner(t, verifiedClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "acts",
		`{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}`)})

	if got.Assertions != 0 {
		t.Fatalf("Assertions = %d, want 0 — an act is not an assertion", got.Assertions)
	}
	if err := got.Err(); err == nil {
		t.Fatal("want a run made only of acts to be red")
	}
}

// --- dispatch -------------------------------------------------------------

func TestRunnerDispatchesOverTheAgentChannel(t *testing.T) {
	channel := &fakeChannel{}
	runner, _ := newRunner(t, stateJSON, channel)

	got := runner.Run([]Check{mustParse(t, "d",
		`{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if len(channel.calls) == 0 || !strings.HasPrefix(channel.calls[0], "pane_open ") {
		t.Fatalf("calls = %v", channel.calls)
	}
	if !strings.Contains(channel.calls[0], `"kind":"db"`) {
		t.Fatalf("params did not reach the channel: %v", channel.calls)
	}
}

// A refused action is a failure carrying the refusal, never a skipped step.
func TestRunnerRecordsARefusedDispatch(t *testing.T) {
	channel := &fakeChannel{errs: map[string]error{"pane_open": fmt.Errorf("the action was refused: no such kind")}}
	runner, _ := newRunner(t, stateJSON, channel)

	got := runner.Run([]Check{mustParse(t, "d",
		`{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the action was refused")
	}
	if !strings.Contains(err.Error(), "refused") {
		t.Fatalf("failure must carry the refusal, got %q", err)
	}
}

func TestRunnerPassesARefusalItExpected(t *testing.T) {
	channel := &fakeChannel{errs: map[string]error{
		"api_set_request": fmt.Errorf("the action was refused: api_set_request: the operator is editing Path"),
	}}
	runner, _ := newRunner(t, stateJSON, channel)
	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"api_set_request","params":{"pane":"api-1"},"refuses":"the operator is editing Path"}}`)})
	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

func TestRunnerFailsARefusesStepWhoseActionRan(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, &fakeChannel{})
	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"api_set_request","params":{"pane":"api-1"},"refuses":"editing"}}`)})
	if err := got.Err(); err == nil || !strings.Contains(err.Error(), "and it ran") {
		t.Fatalf("want a failure saying it ran, got %v", err)
	}
}

func TestRunnerFailsARefusalInOtherWords(t *testing.T) {
	channel := &fakeChannel{errs: map[string]error{"api_cancel": fmt.Errorf("the action was refused: no such pane")}}
	runner, _ := newRunner(t, stateJSON, channel)
	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"api_cancel","params":{"pane":"api-1"},"refuses":"nothing is in flight"}}`)})
	if err := got.Err(); err == nil || !strings.Contains(err.Error(), "not with") {
		t.Fatalf("want a failure naming the expected words, got %v", err)
	}
}

// --- expect: pane ---------------------------------------------------------

func TestRunnerAssertsAPaneField(t *testing.T) {
	channel := &fakeChannel{results: map[string]string{
		"read_pane": `{"id":"db-1","kind":"db","title":"Left"}`,
	}}
	runner, _ := newRunner(t, stateJSON, channel)

	got := runner.Run([]Check{mustParse(t, "p",
		`{"expect":{"pane":"db-1","field":"title","equals":"Left"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

func TestRunnerReportsAPaneFieldMismatch(t *testing.T) {
	channel := &fakeChannel{results: map[string]string{
		"read_pane": `{"id":"db-1","kind":"db","title":"Right"}`,
	}}
	runner, _ := newRunner(t, stateJSON, channel)

	got := runner.Run([]Check{mustParse(t, "p",
		`{"expect":{"pane":"db-1","field":"title","equals":"Left"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the field does not match")
	}
	if !strings.Contains(err.Error(), "Right") || !strings.Contains(err.Error(), "Left") {
		t.Fatalf("failure must carry both values, got %q", err)
	}
}

// A field the snapshot does not carry is a failure naming what was there —
// never a comparison against the empty string, which would pass for
// `equals: ""` and silently assert nothing.
func TestRunnerReportsAnAbsentPaneField(t *testing.T) {
	channel := &fakeChannel{results: map[string]string{"read_pane": `{"id":"db-1"}`}}
	runner, _ := newRunner(t, stateJSON, channel)

	got := runner.Run([]Check{mustParse(t, "p",
		`{"expect":{"pane":"db-1","field":"title","equals":""}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure when the pane carries no such field")
	}
}

// --- expect: tree absent --------------------------------------------------

func TestRunnerAssertsTreeAbsence(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)

	got := runner.Run([]Check{mustParse(t, "t",
		`{"expect":{"tree":"absent","text":"THE LANDING"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

func TestRunnerReportsSomethingThatShouldBeAbsent(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)

	got := runner.Run([]Check{mustParse(t, "t",
		`{"expect":{"tree":"absent","text":"ORGANISATION"}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure when the text is present but asserted absent")
	}
}

// --- expect: process ------------------------------------------------------

func TestRunnerAssertsNoMatchingProcess(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)

	got := runner.Run([]Check{mustParse(t, "proc",
		`{"expect":{"process":{"none-matching":"tail -f"}}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

func TestRunnerReportsAnOrphanedProcess(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Processes = fakeProcesses{matches: map[string][]string{"tail -f": {"9001 tail -f /x"}}}

	got := runner.Run([]Check{mustParse(t, "proc",
		`{"expect":{"process":{"none-matching":"tail -f"}}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when a process survived")
	}
	if !strings.Contains(err.Error(), "9001") {
		t.Fatalf("failure must name what survived, got %q", err)
	}
}

// A process table that could not be read is a failure, never an empty match
// set — otherwise every "nothing survived" assertion passes when `ps` breaks.
func TestRunnerTreatsAnUnreadableProcessTableAsAFailure(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Processes = fakeProcesses{err: fmt.Errorf("ps exploded")}

	got := runner.Run([]Check{mustParse(t, "proc",
		`{"expect":{"process":{"none-matching":"tail -f"}}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure when the process table could not be read")
	}
}

// --- unverified acts ------------------------------------------------------

// The ticket's rule: an act reporting `unverified (synthetic input)` with no
// subsequent confirming state read is a failure, never a pass.
func TestRunnerFailsAnUnverifiedActWithNoConfirmingRead(t *testing.T) {
	runner, _ := newRunner(t, syntheticClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"do":{"click":"landing.row.open:db"}}`,
		`{"expect":{"tree":"contains","text":"ABSOLUTELY NOT PRESENT"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when an unverified act was never confirmed")
	}
	if !strings.Contains(err.Error(), "accessibility action unasserted") {
		t.Fatalf("failure must carry the reason the act was not confirmed, got %q", err)
	}
}

// An unverified act followed by a passing state read is a pass: the read is
// the confirmation the rule asks for.
func TestRunnerAcceptsAnUnverifiedActConfirmedByALaterRead(t *testing.T) {
	runner, _ := newRunner(t, syntheticClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"do":{"click":"landing.row.open:db"}}`,
		`{"expect":{"tree":"contains","text":"standard window Wakil"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass when a later read confirmed the act, got %v", err)
	}
}

// An act at the very end of a check has nothing after it to confirm it.
func TestRunnerFailsAnUnverifiedActAtTheEndOfACheck(t *testing.T) {
	runner, _ := newRunner(t, syntheticClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"expect":{"tree":"contains","text":"standard window Wakil"}}`,
		`{"do":{"click":"landing.row.open:db"}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure for an unverified act with nothing after it")
	}
}

// --- evidence -------------------------------------------------------------

// Every failure writes a screenshot, the tree and a read_pane snapshot, so a
// red run is diagnosable without reproducing it.
func TestRunnerWritesEvidenceOnFailure(t *testing.T) {
	channel := &fakeChannel{results: map[string]string{
		"read_layout": `{"panes":[{"id":"db-1"}]}`,
	}}
	runner, dir := newRunner(t, stateJSON, channel)

	got := runner.Run([]Check{mustParse(t, "landing",
		`{"expect":{"tree":"contains","text":"THE LANDING"}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure")
	}
	entries, err := os.ReadDir(filepath.Join(dir, "landing"))
	if err != nil {
		t.Fatalf("no evidence directory for the failed check: %v", err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	for _, want := range []string{"tree.txt", "panes.json", "failure.txt"} {
		if !containsName(names, want) {
			t.Fatalf("evidence is missing %s, got %v", want, names)
		}
	}
}

// A passing check writes nothing: evidence is for diagnosing red runs, and a
// green run that littered would make the directory useless.
func TestRunnerWritesNoEvidenceWhenEverythingPasses(t *testing.T) {
	runner, dir := newRunner(t, stateJSON, nil)

	got := runner.Run([]Check{mustParse(t, "ok",
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if entries, err := os.ReadDir(dir); err == nil && len(entries) > 0 {
		t.Fatalf("a green run wrote evidence: %v", entries)
	}
}

func containsName(names []string, want string) bool {
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}

// --- quarantine -----------------------------------------------------------

// An intermittent check is quarantined and reported, never silently retried
// into green.
func TestQuarantinedChecksAreReportedAndNeverCountAsPassing(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Quarantined = []string{"flaky"}

	got := runner.Run([]Check{
		mustParse(t, "flaky", `{"expect":{"tree":"contains","text":"THE LANDING"}}`),
		mustParse(t, "solid", `{"expect":{"tree":"contains","text":"ORGANISATION"}}`),
	})

	if err := got.Err(); err != nil {
		t.Fatalf("a quarantined failure must not make the run red, got %v", err)
	}
	if len(got.Quarantined) != 1 || !strings.Contains(got.Quarantined[0], "flaky") {
		t.Fatalf("the quarantined check must be reported, got %v", got.Quarantined)
	}
	if got.ChecksRun != 1 {
		t.Fatalf("ChecksRun = %d, want 1 — a quarantined check is not a check that ran", got.ChecksRun)
	}
}

// `make e2e-run` launches one file at a time, so a quarantined file is a launch
// whose only check is quarantined. Its outcome is reported, which is not
// silence, so the launch must not read as "no check ran" and stop the suite.
func TestALaunchOfOnlyAQuarantinedCheckIsReportedNotRed(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Quarantined = []string{"flaky"}

	got := runner.Run([]Check{
		mustParse(t, "flaky", `{"expect":{"tree":"contains","text":"THE LANDING"}}`),
	})

	if err := got.Err(); err != nil {
		t.Fatalf("a launch of one quarantined check must not be red, got %v", err)
	}
	if len(got.Quarantined) != 1 || got.ChecksRun != 0 {
		t.Fatalf("want it reported and not counted, got %v and ChecksRun %d", got.Quarantined, got.ChecksRun)
	}
}

// Quarantine names a check that is *known* intermittent. A quarantine entry
// matching no check is a stale name, and silently ignoring it is how a
// quarantine list comes to hide a check nobody runs any more.
func TestQuarantineRefusesANameThatMatchesNoCheck(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)
	runner.Quarantined = []string{"deleted-check"}

	got := runner.Run([]Check{mustParse(t, "solid", `{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("want an error for a quarantine entry that matches no check")
	}
}

// --- parity ---------------------------------------------------------------

// varyingChannel answers differently on each call to the same action, so a
// parity comparison can be made to disagree.
type varyingChannel struct {
	replies map[string][]string
	seen    map[string]int
}

func (v *varyingChannel) Call(action string, arguments map[string]interface{}) (ToolResult, error) {
	if v.seen == nil {
		v.seen = map[string]int{}
	}
	bodies, known := v.replies[action]
	if !known {
		return ToolResult{Text: "{}", Structured: json.RawMessage("{}")}, nil
	}
	index := v.seen[action]
	if index >= len(bodies) {
		index = len(bodies) - 1
	}
	v.seen[action]++
	body := bodies[index]
	return ToolResult{Text: body, Structured: json.RawMessage(body)}, nil
}

// Both channels landing the same state is Invariant 2 holding.
func TestParityPassesWhenBothChannelsLandTheSameState(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"focusedId":"db-0"}`, `{"focusedId":"db-1"}`, `{"focusedId":"db-1"}`},
	}}
	exe, _ := fakeOrca(t, verifiedClickJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if got.Assertions != 1 {
		t.Fatalf("Assertions = %d, want 1 — a parity step IS an assertion", got.Assertions)
	}
}

// **The failure this whole harness exists to catch.** The click path and the
// dispatch path reached different state, which is Invariant 2 broken, and it
// is the one thing no fake-injecting unit test can see.
func TestParityReportsTwoChannelsThatDisagree(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"focusedId":"db-0"}`, `{"focusedId":"db-1"}`, `{"focusedId":"db-2"}`},
	}}
	exe, _ := fakeOrca(t, verifiedClickJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the two channels disagree")
	}
	if !strings.Contains(err.Error(), "Invariant 2") {
		t.Fatalf("the failure must name what it means, got %q", err)
	}
	if !strings.Contains(err.Error(), "db-1") || !strings.Contains(err.Error(), "db-2") {
		t.Fatalf("the failure must carry both states, got %q", err)
	}
}

// Key order is not fixed by JSON, and two identical states must not compare
// unequal because a map was serialised in a different order.
func TestParityIgnoresKeyOrder(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"a":1}`, `{"a":1,"b":2}`, `{"b":2,"a":1}`},
	}}
	exe, _ := fakeOrca(t, verifiedClickJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("key order must not make identical states differ, got %v", err)
	}
}

// A parity step that could not drive the click half proves nothing, and must
// never degrade into a single-channel dispatch that passes.
func TestParityFailsWhenTheClickHalfCannotBeDriven(t *testing.T) {
	channel := &varyingChannel{}
	exe, _ := fakeOrca(t, stateJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: refusingResolver(t)},
		Channel: channel, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the click half was refused")
	}
	if !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("failure must carry the refusal, got %q", err)
	}
}

// refusingResolver stands in for a resolver that declines to act — a disabled
// control, say, which must never be pressed and called a pass.
func refusingResolver(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "axresolve")
	body := `{"ok":false,"error":{"code":"disabled","message":"the control is disabled, so ` +
		`pressing it would do nothing and the check would pass on an act that never happened"}}`
	script := "#!/bin/sh\ncat <<'PAYLOAD'\n" + body + "\nPAYLOAD\nexit 1\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

// read_pane needs to know which pane, and a parity step that named none would
// otherwise compare two empty reads and pass.
//
// **Caught at parse time**, because the design doc's own example line omits
// it — so this is a real typo to catch, not a hypothetical one, and catching
// it live would mean dying minutes into a run with a fixture on the screen.
func TestParityThroughReadPaneRequiresAPaneID(t *testing.T) {
	_, err := ParseChecks("par", []byte(
		`{"parity":{"action":"pane_maximize","click":"landing.row.open:db","assert":"read_pane"}}`))
	if err == nil {
		t.Fatal("want a parse error when read_pane parity names no pane")
	}
	if !strings.Contains(err.Error(), "params.id") {
		t.Fatalf("the error must name what is missing, got %q", err)
	}
}

// **The vacuous pass this harness exists to refuse.** Two channels that both
// do nothing agree perfectly. A parity step comparing only the two outcomes
// would go green on a click that pressed nothing and an action that silently
// no-ops, and would count itself an assertion while doing it.
func TestParityRefusesAClickThatChangedNothing(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"focusedId":"db-1"}`, `{"focusedId":"db-1"}`, `{"focusedId":"db-1"}`},
	}}
	exe, _ := fakeOrca(t, verifiedClickJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the click changed nothing — both channels no-opping is not parity")
	}
	if !strings.Contains(err.Error(), "changed nothing") {
		t.Fatalf("the failure must say why, got %q", err)
	}
}

// An unverified click that also changed nothing must name both facts: the
// reason Orca gave is what tells an operator whether to look at the control
// or at the action behind it.
func TestParityNamesAnUnverifiedClickThatChangedNothing(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"focusedId":"db-1"}`, `{"focusedId":"db-1"}`},
	}}
	exe, _ := fakeOrca(t, syntheticClickJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure")
	}
	if !strings.Contains(err.Error(), "accessibility action unasserted") {
		t.Fatalf("the failure must carry why the press was not confirmed, got %q", err)
	}
}

// --- what may confirm an unverified act ----------------------------------

// **`tree: absent` passing is not confirmation.** It passes when the text is
// not there, which is equally what it does when the act never happened, when
// the window never drew, and when the identifier was a typo. It is the
// assertion most likely to pass vacuously, so it is the last thing that
// should certify an act Orca could not assert.
func TestAVacuousAbsenceDoesNotConfirmAnUnverifiedAct(t *testing.T) {
	runner, _ := newRunner(t, syntheticClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"do":{"click":"landing.row.open:db"}}`,
		`{"expect":{"tree":"absent","text":"SOMETHING NEVER PRESENT"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("an absence assertion must not confirm an act that may never have happened")
	}
	if !strings.Contains(err.Error(), "accessibility action unasserted") {
		t.Fatalf("failure must carry the reason the act was not confirmed, got %q", err)
	}
}

// The process table is not the window. A pgrep finding nothing says nothing
// about whether a click landed.
func TestAProcessAssertionDoesNotConfirmAnUnverifiedAct(t *testing.T) {
	runner, _ := newRunner(t, syntheticClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"do":{"click":"landing.row.open:db"}}`,
		`{"expect":{"process":{"none-matching":"tail -f"}}}`)})

	if err := got.Err(); err == nil {
		t.Fatal("a process assertion must not confirm a GUI act")
	}
}

// A positive read of the window IS confirmation: it saw the window in a state
// the act was supposed to produce.
func TestAPositiveTreeReadConfirmsAnUnverifiedAct(t *testing.T) {
	runner, _ := newRunner(t, syntheticClickJSON, nil)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"do":{"click":"landing.row.open:db"}}`,
		`{"expect":{"tree":"contains","text":"standard window Wakil"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass when a positive read confirmed the act, got %v", err)
	}
}

// A pane field read is a positive read of the window too.
func TestAPaneReadConfirmsAnUnverifiedAct(t *testing.T) {
	channel := &fakeChannel{results: map[string]string{"read_pane": `{"id":"db-1","title":"Left"}`}}
	runner, _ := newRunner(t, syntheticClickJSON, channel)

	got := runner.Run([]Check{mustParse(t, "u",
		`{"do":{"click":"landing.row.open:db"}}`,
		`{"expect":{"pane":"db-1","field":"title","equals":"Left"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

// --- settling -------------------------------------------------------------

// changingOrca answers differently once, so an assertion can be made to hold
// only on a later read — the shape a window that settles asynchronously has.
func changingOrca(t *testing.T, first, then string) string {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "orca")
	counter := filepath.Join(dir, "calls")
	script := "#!/bin/sh\n" +
		"n=$(cat " + counter + " 2>/dev/null || echo 0)\n" +
		"echo $((n+1)) > " + counter + "\n" +
		"if [ \"$n\" -lt 1 ]; then cat <<'FIRST'\n" + first + "\nFIRST\n" +
		"else cat <<'THEN'\n" + then + "\nTHEN\n" +
		"fi\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

// **A predicate with a deadline, never a fixed sleep.** The assertion is
// re-read until it holds; a harness that read once would call this a failure,
// and one that slept a fixed interval would pay that interval on every green
// run.
func TestAnAssertionWaitsForTheWindowToSettle(t *testing.T) {
	absent := `{"ok":true,"result":{"snapshot":{"elementCount":9,"treeText":"0 window\n"}}}`
	present := `{"ok":true,"result":{"snapshot":{"elementCount":51,"treeText":"0 window\n\t1 text THE LANDING\n"}}}`
	runner := &Runner{
		Orca: Orca{Exe: changingOrca(t, absent, present)}, PID: 44187,
		Settle: 2 * time.Second, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "settle",
		`{"expect":{"tree":"contains","text":"THE LANDING"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("the assertion should have settled, got %v", err)
	}
}

// A predicate that never holds still fails, and the failure says what the
// window actually held rather than merely that it timed out.
func TestAnAssertionThatNeverSettlesStillFails(t *testing.T) {
	absent := `{"ok":true,"result":{"snapshot":{"elementCount":9,"treeText":"0 window\n"}}}`
	exe, _ := fakeOrca(t, absent, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, PID: 44187,
		Settle: 300 * time.Millisecond, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "settle",
		`{"expect":{"tree":"contains","text":"NEVER ARRIVES"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the predicate never holds")
	}
	if !strings.Contains(err.Error(), "NEVER ARRIVES") {
		t.Fatalf("the failure must say what was not found, got %q", err)
	}
}

// --- parity settles before it compares ------------------------------------

// **Transient state must not fail a parity that holds.** Measured live: a
// `pane_focus` parity compared identical focusedIds and failed anyway, on
// `busy: true` versus `busy: false` for a terminal whose shell was still
// starting at the first read and had settled by the second. The channels
// agreed about everything the action governs.
func TestParitySettlesThroughATransient(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		// before: settles at once. after the click: busy, then not. after the
		// dispatch: already settled to the same thing.
		"read_layout": {
			`{"focusedId":"t-2","busy":false}`, `{"focusedId":"t-2","busy":false}`,
			`{"focusedId":"t-1","busy":true}`, `{"focusedId":"t-1","busy":false}`,
			`{"focusedId":"t-1","busy":false}`,
		},
	}}
	exe, _ := fakeOrca(t, stateJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Settle: 2 * time.Second,
		Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("a transient must not fail a parity that holds, got %v", err)
	}
}

// A field that never settles is reported rather than hidden: quiescence is the
// predicate precisely so nothing has to maintain a denylist of fields to skip.
func TestParityReportsStateThatNeverSettles(t *testing.T) {
	channel := &neverSettling{}
	exe, _ := fakeOrca(t, stateJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Settle: 300 * time.Millisecond,
		Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"pane_focus","click":"landing.row.open:db","assert":"read_layout"}}`)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the state never stops changing")
	}
	if !strings.Contains(err.Error(), "never stopped changing") {
		t.Fatalf("the failure must say why, got %q", err)
	}
}

// neverSettling answers differently every single time.
type neverSettling struct{ n int }

func (s *neverSettling) Call(action string, arguments map[string]interface{}) (ToolResult, error) {
	s.n++
	body := fmt.Sprintf(`{"tick":%d}`, s.n)
	return ToolResult{Text: body, Structured: json.RawMessage(body)}, nil
}

// --- a drag parity waits for its drop to land -----------------------------

// dragParity is a drag parity asserting through read_layout — the fake
// channel answers read_layout from its replies, and the runner reads it the
// same way for every parity.
const dragParity = `{"parity":{"action":"api_bind","params":{"pane":"api-2","source":"db-1","row":0},` +
	`"drag":{"from":"db.row.0.grip","to":"api.pane"},"assert":"read_layout"}}`

// **A drop lands after the drag returns** (2c-iv, Ruling 9). Measured live:
// the first reads after the drag still showed `before`, and a parity that
// settled on them refused a bind that landed an instant later. The state here
// changes only on the fourth read after the drag, and the parity must see it.
func TestADragParityWaitsForTheDropToLand(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {
			// before, settled.
			`{"bound":false}`, `{"bound":false}`,
			// after the drag: three reads of the old state, then the drop.
			`{"bound":false}`, `{"bound":false}`, `{"bound":false}`, `{"bound":true}`,
			// settling, and after the dispatch: the same state.
			`{"bound":true}`,
		},
	}}
	exe, _ := fakeOrca(t, stateJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Settle: 2 * time.Second,
		Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "drop", dragParity)})

	if err := got.Err(); err != nil {
		t.Fatalf("a drop that lands after the drag returns must pass, got %v", err)
	}
	// The act is never repeated: one drag, whatever the waiting.
	if n := channel.seen["read_layout"]; n < 6 {
		t.Fatalf("read_layout was read %d times; the wait must have read past the stale state", n)
	}
}

// A drop that never lands is still refused, with the message every parity
// uses: the wait is bounded, and running out of it is exactly "changed
// nothing".
func TestADragParityWhoseDropNeverLandsChangedNothing(t *testing.T) {
	channel := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"bound":false}`},
	}}
	exe, _ := fakeOrca(t, stateJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: channel, PID: 44187, Settle: 300 * time.Millisecond,
		Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "drop", dragParity)})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure when the drop never changed the state")
	}
	if !strings.Contains(err.Error(), "dragging db.row.0.grip onto api.pane changed nothing") {
		t.Fatalf("the failure must be the parity's own refusal, got %q", err)
	}
}
