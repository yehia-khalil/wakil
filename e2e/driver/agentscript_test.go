package driver

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeScript(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), AgentScriptFile)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("writing the script: %v", err)
	}
	return path
}

func TestAScriptAnswersThePromptItWasWrittenFor(t *testing.T) {
	path := writeScript(t, `{"rules":[
	  {"match":"propose","call":{"action":"term_propose","params":{"pane":"terminal-1","command":"echo one"}},
	   "reply":"proposed"},
	  {"match":"last command","read":{"pane":"terminal-1","field":"blocks[-1].output"},
	   "reply":"it printed {value}"}
	]}`)
	script, err := LoadAgentScript(path)
	if err != nil {
		t.Fatalf("loading the script: %v", err)
	}

	// **Matched on a substring, case-folded.** A check types a sentence at a
	// composer; a rule that had to equal it would be a rule nobody could keep
	// in step with the check.
	rule, found := script.Rule("Please PROPOSE a command for me")
	if !found {
		t.Fatal("the prompt names the rule's trigger")
	}
	if rule.Call == nil || rule.Call.Action != "term_propose" {
		t.Fatalf("want the proposing rule, got %+v", rule)
	}

	reading, found := script.Rule("what did my last command print?")
	if !found {
		t.Fatal("the second rule matches its own prompt")
	}
	if reading.Read == nil || reading.Read.Field != "blocks[-1].output" {
		t.Fatalf("want the reading rule, got %+v", reading)
	}
	if got := reading.Render("hello"); got != "it printed hello" {
		t.Fatalf("the reply carries what was read, got %q", got)
	}
}

// **A prompt no rule matches is an error, never a bland answer.** A stub that
// answered "I could not help with that" would let a check whose prompt had
// drifted pass on an answer that proves nothing — the silent success this
// harness exists to refuse.
func TestAPromptNoRuleMatchesIsNotAnswered(t *testing.T) {
	path := writeScript(t, `{"rules":[{"match":"propose","reply":"ok"}]}`)
	script, err := LoadAgentScript(path)
	if err != nil {
		t.Fatalf("loading the script: %v", err)
	}
	if _, found := script.Rule("something else entirely"); found {
		t.Fatal("no rule covers this prompt, and the stub must say so rather than improvise")
	}
}

// A script with no rules answers nothing, so every check driving the agent
// would fail for the same reason — and the reason would be in the wrong place.
func TestAnEmptyScriptIsRefusedWhenItIsLoaded(t *testing.T) {
	path := writeScript(t, `{"rules":[]}`)
	if _, err := LoadAgentScript(path); err == nil {
		t.Fatal("a stub with no rules cannot answer anything")
	}
}

func TestARuleWithNoTriggerIsRefused(t *testing.T) {
	path := writeScript(t, `{"rules":[{"reply":"ok"}]}`)
	_, err := LoadAgentScript(path)
	if err == nil {
		t.Fatal("a rule that matches everything would answer every prompt with one reply")
	}
	if !strings.Contains(err.Error(), "match") {
		t.Fatalf("the refusal names the missing field, got %q", err)
	}
}

// **A reply that interpolates what was read, from a rule that reads nothing,
// would render the placeholder as text.** A check asserting on the answer
// would then be asserting on the word "{value}".
func TestAReplyThatInterpolatesWithoutReadingIsRefused(t *testing.T) {
	path := writeScript(t, `{"rules":[{"match":"x","reply":"it printed {value}"}]}`)
	_, err := LoadAgentScript(path)
	if err == nil {
		t.Fatal("nothing would fill the placeholder")
	}
	if !strings.Contains(err.Error(), "{value}") {
		t.Fatalf("the refusal shows the placeholder, got %q", err)
	}
}

// A rule that neither acts nor reads nor replies is a prompt the stub accepts
// and does nothing about, which is indistinguishable from a broken harness.
func TestARuleThatDoesNothingIsRefused(t *testing.T) {
	path := writeScript(t, `{"rules":[{"match":"x"}]}`)
	if _, err := LoadAgentScript(path); err == nil {
		t.Fatal("a rule with no reply, no call and no read does nothing at all")
	}
}

func TestAMissingScriptSaysWhereItWasLookedFor(t *testing.T) {
	path := filepath.Join(t.TempDir(), AgentScriptFile)
	_, err := LoadAgentScript(path)
	if err == nil {
		t.Fatal("a stub with no script must not start")
	}
	if !strings.Contains(err.Error(), path) {
		t.Fatalf("the refusal names the path, got %q", err)
	}
}

// The rules are tried in order, so a broad trigger written first cannot
// shadow a narrow one silently — it shadows it visibly, in the file.
func TestTheFirstMatchingRuleWins(t *testing.T) {
	path := writeScript(t, `{"rules":[
	  {"match":"command","reply":"broad"},
	  {"match":"last command","reply":"narrow"}
	]}`)
	script, err := LoadAgentScript(path)
	if err != nil {
		t.Fatalf("loading the script: %v", err)
	}
	rule, _ := script.Rule("what did my last command print?")
	if rule.Reply != "broad" {
		t.Fatalf("the first matching rule answers, got %q", rule.Reply)
	}
}

// Workspaces, piece 1: the window appends the workspace map after the operator's words. A rule
// matches the words only — a map naming another conversation's title must not trigger its rule —
// and `{map}` reads the map's first line, nothing when the turn carried none.
func TestARuleMatchesTheWordsAndReadsTheMapAfterThem(t *testing.T) {
	path := writeScript(t, `{"rules":[
	  {"match":"start the held agent","reply":"held"},
	  {"match":"where do you work","reply":"map says: {map}"}
	]}`)
	script, err := LoadAgentScript(path)
	if err != nil {
		t.Fatalf("loading the script: %v", err)
	}
	prompt := "where do you work\n\n[Wakil: where you work. This map replaces any earlier one.]\n" +
		"You are in Main of project api (staging).\nOther conversations in Main:\n- ‘start the held agent’ (working)"
	rule, found := script.Rule(prompt)
	if !found || rule.Reply != "map says: {map}" {
		t.Fatalf("the words' rule answers, got %q", rule.Reply)
	}
	if got := MapLine(prompt); got != "You are in Main of project api (staging)." {
		t.Fatalf("MapLine = %q", got)
	}
	if got := MapLine("where do you work"); got != "" {
		t.Fatalf("a turn with no map reads %q", got)
	}
}

// A frame with no `type` is one StreamJSON decodes as nothing, so a check
// waiting on what it carries would wait on a frame that never arrived.
func TestAnEmittedFrameWithNoTypeIsRefused(t *testing.T) {
	path := writeScript(t, `{"rules":[{"match":"x","emit":[{"rate_limit_info":{}}],"reply":"ok"}]}`)
	_, err := LoadAgentScript(path)
	if err == nil {
		t.Fatal("an untyped frame decodes as nothing")
	}
	if !strings.Contains(err.Error(), "type") {
		t.Fatalf("the refusal names the missing field, got %q", err)
	}
}

// The shipped script's capacity rule emits the rate_limit_event the
// agent/capacity-after-turn check waits on.
func TestTheShippedScriptEmitsARateLimitEvent(t *testing.T) {
	script, err := LoadAgentScript(filepath.Join("..", "stub", "script.json"))
	if err != nil {
		t.Fatalf("loading the shipped script: %v", err)
	}
	rule, found := script.Rule("report my capacity at twelve percent")
	if !found || len(rule.Emit) != 1 || rule.Emit[0]["type"] != "rate_limit_event" {
		t.Fatalf("want one rate_limit_event frame, got %+v", rule)
	}
}

// The second capacity rule reads differently from the stub API's launch
// reading (12/59), so agent/capacity-after-turn can tell a turn's stream
// from the launch probe.
func TestTheShippedScriptHasASecondCapacityRule(t *testing.T) {
	script, err := LoadAgentScript(filepath.Join("..", "stub", "script.json"))
	if err != nil {
		t.Fatalf("loading the shipped script: %v", err)
	}
	rule, found := script.Rule("report my capacity at twenty-nine percent")
	if !found || len(rule.Emit) != 1 || rule.Emit[0]["type"] != "rate_limit_event" {
		t.Fatalf("want one rate_limit_event frame, got %+v", rule)
	}
}

// A hold is released by `touch ~/<name>`, so a name that is a path names a
// file no check can know how to make, and the turn would only ever time out.
func TestAHoldThatIsNotAPlainFileNameIsRefused(t *testing.T) {
	for _, hold := range []string{"a/b", "..", `a\b`} {
		path := writeScript(t, `{"rules":[{"match":"x","reply":"y","hold":`+strconvQuote(hold)+`}]}`)
		if _, err := LoadAgentScript(path); err == nil {
			t.Fatalf("a hold on %q was accepted", hold)
		}
	}
	path := writeScript(t, `{"rules":[{"match":"x","reply":"y","hold":"release-x"}]}`)
	script, err := LoadAgentScript(path)
	if err != nil {
		t.Fatalf("a plain hold was refused: %v", err)
	}
	if script.Rules[0].Hold != "release-x" {
		t.Fatalf("the hold did not survive loading: %+v", script.Rules[0])
	}
}

func strconvQuote(s string) string {
	encoded, _ := json.Marshal(s)
	return string(encoded)
}
