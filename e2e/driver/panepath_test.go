package driver

import (
	"encoding/json"
	"strings"
	"testing"
)

// terminalPane is a real `read_pane` reply for a terminal pane, taken from a
// live fixture instance on 2026-09-23 after `ls` in a fresh pane.
//
// **Copied from a measurement, not invented.** A hand-written fixture here
// would be a second answer to "what does a terminal pane look like", and the
// one that never gets corrected when the wire shape moves.
const terminalPane = `{
  "kind": "terminal",
  "shell": "zsh",
  "commandRunning": false,
  "promptRow": 0,
  "cursorCol": 34,
  "grid": ["operator@192 project % ls", "", ""],
  "blocks": [
    {"id": "83719DA7-1", "command": "true", "exitCode": 0, "durationMs": 1,
     "origin": "operator", "output": [], "heldTheGrid": false},
    {"id": "83719DA7-2", "command": "ls", "exitCode": 0, "durationMs": 6,
     "origin": "operator", "output": ["notes.txt"], "heldTheGrid": false}
  ]
}`

func paneFixture(t *testing.T) map[string]interface{} {
	t.Helper()
	var fields map[string]interface{}
	if err := json.Unmarshal([]byte(terminalPane), &fields); err != nil {
		t.Fatal(err)
	}
	return fields
}

// A top-level field still works exactly as it did — the path grammar is a
// superset, not a replacement.
func TestPanePathReadsATopLevelField(t *testing.T) {
	value, err := PanePath(paneFixture(t), "shell")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if scalar(value) != "zsh" {
		t.Fatalf("got %q", scalar(value))
	}
}

// **`[-1]` is the last element, and it is the index every terminal check
// wants.** A check asserts about the command it just ran, and a positive
// index would have to be counted by hand and would change the moment a step
// was inserted above it.
func TestPanePathReadsTheLastElementOfAnArray(t *testing.T) {
	value, err := PanePath(paneFixture(t), "blocks[-1].command")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if scalar(value) != "ls" {
		t.Fatalf("want the last block's command, got %q", scalar(value))
	}
}

func TestPanePathReadsAPositiveIndex(t *testing.T) {
	value, err := PanePath(paneFixture(t), "blocks[0].exitCode")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if scalar(value) != "0" {
		t.Fatalf("got %q", scalar(value))
	}
}

// **An index past the end names what was there.** `blocks[3]` on a pane with
// two blocks is the commonest mistake a terminal check makes — the command
// did not run, or has not sealed yet — and "index 3 of 2" says which.
func TestPanePathNamesTheLengthWhenAnIndexIsPastTheEnd(t *testing.T) {
	_, err := PanePath(paneFixture(t), "blocks[3].command")
	if err == nil {
		t.Fatal("want an error")
	}
	if !strings.Contains(err.Error(), "2") {
		t.Fatalf("the error must say how many there were, got %q", err)
	}
}

// **`blocks[-1]` on an empty array is the specimen failure of this whole
// harness**, not an edge case: it is what a check sees when the command it
// typed never ran. It must say so rather than reading as a missing field.
func TestPanePathRefusesTheLastElementOfAnEmptyArray(t *testing.T) {
	_, err := PanePath(map[string]interface{}{"blocks": []interface{}{}}, "blocks[-1].command")
	if err == nil {
		t.Fatal("want an error")
	}
	if !strings.Contains(err.Error(), "empty") {
		t.Fatalf("the error must say the array was empty, got %q", err)
	}
}

// A misspelled segment lists what was actually there, which is what turns a
// typo into a one-line fix instead of a second live run.
func TestPanePathListsWhatIsThereWhenASegmentIsMissing(t *testing.T) {
	_, err := PanePath(paneFixture(t), "blocks[-1].exit_code")
	if err == nil {
		t.Fatal("want an error")
	}
	if !strings.Contains(err.Error(), "exitCode") {
		t.Fatalf("the error must list the keys that are there, got %q", err)
	}
}

// Indexing something that is not an array says so rather than reporting an
// absent field, because the two send a reader to opposite places.
func TestPanePathRefusesAnIndexIntoSomethingThatIsNotAnArray(t *testing.T) {
	_, err := PanePath(paneFixture(t), "shell[0]")
	if err == nil {
		t.Fatal("want an error")
	}
	if !strings.Contains(err.Error(), "not a list") {
		t.Fatalf("got %q", err)
	}
}

// **`contains` exists because the interesting values are lists.** `grid` is
// twenty rows of padded text and a block's `output` is one string per line;
// nothing a check cares about there is ever equal to a literal an author
// could write down, and an `equals` against a whole grid would be rewritten
// every time the window resized.
func TestExpectPaneContainsMatchesInsideAList(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	text := "ls"
	if err := runner.assertPane(&Expect{Pane: "terminal-1", Field: "grid", Contains: &text}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

func TestExpectPaneContainsReportsWhatItSawInstead(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	text := "kubectl"
	err := runner.assertPane(&Expect{Pane: "terminal-1", Field: "grid", Contains: &text})
	if err == nil {
		t.Fatal("want a failure")
	}
	if !strings.Contains(err.Error(), "operator@192") {
		t.Fatalf("the failure must show what the field held, got %q", err)
	}
}

// **A pane step names exactly one predicate.** One carrying both would assert
// whichever the runner checked first, and one carrying neither passes on the
// mere existence of the field — which is the vacuous assertion this harness
// exists to refuse.
func TestParseChecksRefusesAPaneStepWithBothPredicates(t *testing.T) {
	_, err := ParseChecks("terminal", []byte(
		`{"expect":{"pane":"terminal-1","field":"shell","equals":"zsh","contains":"z"}}`+"\n"))
	if err == nil {
		t.Fatal("want a refusal")
	}
	if !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("got %q", err)
	}
}

func TestParseChecksAcceptsAPathAndAContains(t *testing.T) {
	check, err := ParseChecks("terminal", []byte(
		`{"expect":{"pane":"terminal-1","field":"blocks[-1].exitCode","equals":"0"}}`+"\n"+
			`{"expect":{"pane":"terminal-1","field":"grid","contains":"brew"}}`+"\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(check.Steps) != 2 {
		t.Fatalf("got %d steps", len(check.Steps))
	}
}

// paneChannel answers every read_pane with one body.
func paneChannel(body string) *fakeChannel {
	return &fakeChannel{results: map[string]string{"read_pane": body}}
}

// **`present` is for a live measurement whose VALUE is not the claim.**
// 2c-iii's check 2 is "a block appears carrying its exit code and duration";
// the exit code is a value a check can write down and the duration is six
// milliseconds today and nine tomorrow. Asserting the path resolves is the
// whole of that claim and nothing more.
func TestExpectPanePresentAssertsThePathResolves(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	yes := true
	if err := runner.assertPane(&Expect{
		Pane: "terminal-1", Field: "blocks[-1].durationMs", Present: &yes}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

// It is not vacuous, and this is what proves it: the same assertion against a
// pane with no blocks fails, naming the empty list.
func TestExpectPanePresentFailsWhenThereIsNoSuchPath(t *testing.T) {
	runner := &Runner{Channel: paneChannel(`{"kind":"terminal","blocks":[]}`)}
	yes := true
	err := runner.assertPane(&Expect{
		Pane: "terminal-1", Field: "blocks[-1].durationMs", Present: &yes})
	if err == nil {
		t.Fatal("want a failure: there is no block, so it carries no duration")
	}
	if !strings.Contains(err.Error(), "empty") {
		t.Fatalf("got %q", err)
	}
}

// `present: false` asserts a path is NOT there — a block that held the grid
// records no output, for instance. It fails when the path resolves.
func TestExpectPanePresentFalseFailsWhenThePathIsThere(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	no := false
	if err := runner.assertPane(&Expect{
		Pane: "terminal-1", Field: "shell", Present: &no}); err == nil {
		t.Fatal("want a failure: shell is there")
	}
}

func TestParseChecksRefusesAPaneStepWithPresentAndEquals(t *testing.T) {
	_, err := ParseChecks("terminal", []byte(
		`{"expect":{"pane":"p","field":"shell","present":true,"equals":"zsh"}}`+"\n"))
	if err == nil {
		t.Fatal("want a refusal")
	}
}

// **`present` must refuse an explicit null, and the retrodiction is what
// proved it.** With 2c-iii's live-prompt defect put back —
// `promptRow: nil, cursorRow: nil, cursorCol: nil`, the shape the phase-log
// records as "the view kept passing nil" — check 3 PASSED. `PaneSnapshot`'s
// own rule is that every key of the answered kind is always present,
// "including when false, empty or null", so a predicate that only asked
// whether the key was there could never fail against this wire shape: it was
// vacuous by construction, and the one thing it was written to catch was
// exactly what it could not see.
//
// A check that does want "the key is there holding null" says
// `equals: "null"`, which is expressible and says what it means.
func TestExpectPanePresentRefusesAnExplicitNull(t *testing.T) {
	runner := &Runner{Channel: paneChannel(`{"kind":"terminal","promptRow":null}`)}
	yes := true
	err := runner.assertPane(&Expect{Pane: "terminal-1", Field: "promptRow", Present: &yes})
	if err == nil {
		t.Fatal("want a failure: the key is there and holds nothing")
	}
	if !strings.Contains(err.Error(), "null") {
		t.Fatalf("the failure must say the value was null, got %q", err)
	}
}

func TestExpectPaneEqualsNullIsStillExpressible(t *testing.T) {
	runner := &Runner{Channel: paneChannel(`{"kind":"terminal","promptRow":null}`)}
	null := "null"
	if err := runner.assertPane(&Expect{Pane: "terminal-1", Field: "promptRow", Equals: &null}); err != nil {
		t.Fatalf("asserting a key holds null must stay expressible: %v", err)
	}
}

// `present: false` accepts a null for the same reason: a key holding nothing
// is the absence this predicate is about.
func TestExpectPanePresentFalseAcceptsAnExplicitNull(t *testing.T) {
	runner := &Runner{Channel: paneChannel(`{"kind":"terminal","promptRow":null}`)}
	no := false
	if err := runner.assertPane(&Expect{Pane: "terminal-1", Field: "promptRow", Present: &no}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

// **A malformed path is refused at parse time, because `present: false` could
// never catch one.** A path that cannot parse does not resolve, and "did not
// resolve" is exactly what `present: false` asserts — so a typo would pass
// against every build, having looked at nothing. Found by review.
func TestParseChecksRefusesAMalformedPanePath(t *testing.T) {
	for _, field := range []string{"blocks[-1]].exitCode", "blocks[x].exitCode", "blocks..command", ""} {
		line := `{"expect":{"pane":"p","field":"` + field + `","present":false}}`
		if _, err := ParseChecks("terminal", []byte(line+"\n")); err == nil {
			t.Errorf("%s: want a refusal", line)
		}
	}
}

func TestParseChecksAcceptsTheWellFormedPaths(t *testing.T) {
	for _, field := range []string{"shell", "blocks[-1].exitCode", "blocks[0].output", "blocks"} {
		if err := ValidPanePath(field); err != nil {
			t.Errorf("%s: unexpected refusal: %v", field, err)
		}
	}
}

// **`present: false` asserts a LEAF is absent from a container that exists.**
// Without that rule it is satisfied by any path that fails to resolve, which
// includes a misspelled one — so `blcoks[-1].exitCode` passed against every
// build, having looked at nothing. Parse-time grammar checking narrowed the
// hole (it catches `blocks[1`) and could never close it, because a typo is
// grammatically a perfectly good name. Found in review, after the first fix
// claimed more than it did.
func TestExpectPanePresentFalseRefusesAPathWhoseContainerIsMissing(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	no := false
	err := runner.assertPane(&Expect{
		Pane: "terminal-1", Field: "blcoks[-1].exitCode", Present: &no})
	if err == nil {
		t.Fatal("want a failure: `blcoks` is not there, so this asserted nothing about exitCode")
	}
	if !strings.Contains(err.Error(), "blcoks") {
		t.Fatalf("the failure must name the segment that is missing, got %q", err)
	}
}

// The legitimate case still passes: the container resolves and the leaf is
// genuinely not on it.
func TestExpectPanePresentFalsePassesWhenTheContainerHasNoSuchLeaf(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	no := false
	if err := runner.assertPane(&Expect{
		Pane: "terminal-1", Field: "blocks[-1].proposal", Present: &no}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

// A single-segment path has the pane itself as its container, which always
// exists — so `present: false` on a top-level key is the leaf rule too.
func TestExpectPanePresentFalseOnATopLevelKey(t *testing.T) {
	runner := &Runner{Channel: paneChannel(terminalPane)}
	no := false
	if err := runner.assertPane(&Expect{
		Pane: "terminal-1", Field: "backfilledAt", Present: &no}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

// **`present: false` must not certify an unverified act.** It is the same
// negative shape as `tree: absent` — it passes when nothing happened — and it
// confirmed because Confirms asked only whether a pane was named. Found in
// review; latent, but it is this harness's own thesis.
func TestPresentFalseDoesNotConfirmAnUnverifiedAct(t *testing.T) {
	no, yes := false, true
	if (&Expect{Pane: "p", Field: "x", Present: &no}).Confirms() {
		t.Fatal("a negative read is never evidence an act landed")
	}
	if !(&Expect{Pane: "p", Field: "x", Present: &yes}).Confirms() {
		t.Fatal("a positive read is")
	}
	equals := "zsh"
	if !(&Expect{Pane: "p", Field: "shell", Equals: &equals}).Confirms() {
		t.Fatal("so is equals")
	}
}
