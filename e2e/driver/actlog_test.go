package driver

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTheActLogNamesWhatWasFrontAtEachAct pins the line a red check leaves
// about what it did.
//
// **The defect this exists for is invisible in every other artefact.** #284's
// silent press reports success, so the screenshot shows a window that looks
// fine and the tree shows a control that is there and enabled. What the window
// server believed is the only thing that differs, and nothing recorded it.
func TestTheActLogNamesWhatWasFrontAtEachAct(t *testing.T) {
	runner := &Runner{atLastAct: &Frontmost{
		PID: 501, BundleID: "dev.wakil.e2e", IsTarget: true,
		TargetHasFocusedWindow: true, FocusedIdentifier: "window.composer",
	}}
	runner.logAct("both-surfaces.jsonl step 10", &Do{Click: "window.send"}, nil)

	line := runner.acts[0]
	for _, want := range []string{
		"step 10", "click window.send", "ok",
		"dev.wakil.e2e", "pid 501", "window.composer",
	} {
		if !strings.Contains(line, want) {
			t.Errorf("the act log does not say %q: %s", want, line)
		}
	}
}

// TestTheActLogShoutsWhenTheFixtureWasNotFront is the reading the log was
// added to catch. A press into a window that is not front, or has no focused
// window at all, must not read like an ordinary line.
func TestTheActLogShoutsWhenTheFixtureWasNotFront(t *testing.T) {
	runner := &Runner{atLastAct: &Frontmost{
		PID: 99, BundleID: "com.apple.finder", IsTarget: false,
		TargetHasFocusedWindow: false,
	}}
	runner.logAct("x step 1", &Do{Click: "window.send"}, nil)

	line := runner.acts[0]
	if !strings.Contains(line, "NOT the fixture") {
		t.Errorf("a press while another app was front reads as ordinary: %s", line)
	}
	if !strings.Contains(line, "NO FOCUSED WINDOW") {
		t.Errorf("a press into an app with no window reads as ordinary: %s", line)
	}
	if !strings.Contains(line, "com.apple.finder") {
		t.Errorf("the act log does not name what took the screen: %s", line)
	}
}

// TestAnActWhoseChannelReportsNothingSaysSo keeps the log honest about its own
// gaps. Orca delivers the keystroke arms and reports no such reading, and a
// line that silently omitted it would read as "the fixture was front".
func TestAnActWhoseChannelReportsNothingSaysSo(t *testing.T) {
	runner := &Runner{}
	runner.logAct("x step 1", &Do{Keys: "echo hi"}, nil)

	line := runner.acts[0]
	if !strings.Contains(line, "not asked") {
		t.Errorf("an act with no reading does not say so: %s", line)
	}
	if strings.Contains(line, "frontmost pid") {
		t.Errorf("an act with no reading claims one: %s", line)
	}
}

// TestTheActLogCarriesTheTextATypeSent is what separates #284's send-with-an-
// empty-composer from a send that carried the prompt.
func TestTheActLogCarriesTheTextATypeSent(t *testing.T) {
	runner := &Runner{}
	runner.logAct("x step 9", &Do{Type: &TypeInto{
		Into: "window.composer", Text: "what did my last command print?"}}, nil)

	if !strings.Contains(runner.acts[0], "what did my last command print?") {
		t.Errorf("the act log does not carry the text: %s", runner.acts[0])
	}
}

// TestAFailingCheckLeavesItsActsBesideWhatItSaw proves the log reaches the
// evidence directory, which is the only place anyone will read it.
func TestAFailingCheckLeavesItsActsBesideWhatItSaw(t *testing.T) {
	dir := t.TempDir()
	evidence := &Evidence{Dir: dir}
	evidence.Acts("two-enter.jsonl", []string{"step 1: click window.send -> ok; frontmost x"})

	if err := evidence.Record("two-enter.jsonl", []string{"step 2: it did not"}); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(dir, "two-enter.jsonl", "acts.txt"))
	if err != nil {
		t.Fatalf("a red check left no act log: %v", err)
	}
	if !strings.Contains(string(body), "click window.send") {
		t.Errorf("the act log holds %q", body)
	}
	if !slicesContains(evidence.Gathered("two-enter.jsonl"), "acts.txt") {
		t.Errorf("acts.txt was written and not reported as gathered: %v",
			evidence.Gathered("two-enter.jsonl"))
	}
}

// TestACheckThatDidNothingLeavesNoEmptyActLog — an artefact that is always
// there says nothing by being there, and a reader who finds an empty one
// learns the wrong thing about a check that never acted.
func TestACheckThatDidNothingLeavesNoEmptyActLog(t *testing.T) {
	dir := t.TempDir()
	evidence := &Evidence{Dir: dir}
	evidence.Acts("x", nil)
	if err := evidence.Record("x", []string{"it did not"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "x", "acts.txt")); !os.IsNotExist(err) {
		t.Errorf("a check that performed no act still left an act log (%v)", err)
	}
}

func slicesContains(haystack []string, needle string) bool {
	for _, item := range haystack {
		if item == needle {
			return true
		}
	}
	return false
}

// TestAReadingThatCouldNotBeTakenSaysWhy — "not asked" and "asked and it
// failed" are different facts, and the first reads as though the harness chose
// not to look. This is the shape the live run hit: `--frontmost` reports no
// window, the strict reader demanded one, and the line went blank with nothing
// said about it.
func TestAReadingThatCouldNotBeTakenSaysWhy(t *testing.T) {
	failed := errors.New("axresolve reported success with no window")
	runner := &Runner{beforeLastActErr: failed, atLastActErr: failed}
	runner.logAct("x step 2", &Do{Keys: "vim"}, nil)

	line := runner.acts[0]
	if !strings.Contains(line, "no window") {
		t.Errorf("a reading that failed reads as one that was never taken: %s", line)
	}
	if strings.Contains(line, "not asked") {
		t.Errorf("a failed reading claims it was never asked for: %s", line)
	}
}

// TestFrontmostRefusesToSayNothingAboutAReplyItCannotRead keeps the resolver
// wrapper from swallowing its own failure, which is how the gap above got
// into a live run.
func TestFrontmostRefusesToSayNothingAboutAReplyItCannotRead(t *testing.T) {
	for _, reply := range []struct{ name, body string }{
		{"a reply with no reading", `{"ok":true,"pid":7}`},
		{"a refusal", `{"ok":false,"error":{"code":"x","message":"y"}}`},
		{"not JSON at all", `axresolve: killed`},
	} {
		got, err := (Resolver{Exe: actLogResolver(t, reply.body)}).Frontmost(7)
		if err == nil {
			t.Errorf("%s produced %+v and no error", reply.name, got)
		}
		if got != nil {
			t.Errorf("%s produced a reading: %+v", reply.name, got)
		}
	}
}

// And the reply it CAN read comes back whole, window or no window — the mode
// exists to answer for an app that presents none.
func TestFrontmostReadsAReplyThatCarriesNoWindow(t *testing.T) {
	got, err := (Resolver{Exe: actLogResolver(t,
		`{"ok":true,"pid":7,"frontmost":{"pid":7,"bundleId":"dev.wakil.e2e",`+
			`"isTarget":true,"targetHasFocusedWindow":false,"focusedRole":"AXTextField"}}`)}).
		Frontmost(7)
	if err != nil {
		t.Fatalf("a windowless reply was refused: %v", err)
	}
	if !got.IsTarget || got.TargetHasFocusedWindow {
		t.Errorf("got %+v", got)
	}
	if !strings.Contains(got.String(), "AXTextField") {
		t.Errorf("an unnamed focused element loses its role: %s", got.String())
	}
}

func actLogResolver(t *testing.T, body string) string {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "axresolve")
	if err := os.WriteFile(exe,
		[]byte("#!/bin/sh\ncat <<'PAYLOAD'\n"+body+"\nPAYLOAD\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestAnActDeliveredIntoAnotherAppIsCaughtBeforeItIsMade is the finding this
// whole instrument produced, as a unit.
//
// #284, measured under load: `com.stablyai.orca` — the harness's own actuation
// tool — was frontmost when it delivered `keys "vim"`, so vim never opened and
// Orca reported `ok`. It always would: a keystroke goes to whoever holds the
// foreground, and Orca had it, so nothing was refused and nothing was wrong
// with the reply. Activate-on-refusal cannot reach that; only a reading taken
// BEFORE the act can.
func TestAnActDeliveredIntoAnotherAppIsCaughtBeforeItIsMade(t *testing.T) {
	notTheFixture := &Frontmost{PID: 81744, BundleID: "com.stablyai.orca", IsTarget: false,
		TargetHasFocusedWindow: true}
	theFixture := &Frontmost{PID: 81826, BundleID: "dev.wakil.e2e", IsTarget: true,
		TargetHasFocusedWindow: true, FocusedIdentifier: "window.composer"}

	runner := &Runner{beforeLastAct: notTheFixture, atLastAct: theFixture}
	runner.logAct("both-surfaces.jsonl step 6", &Do{Keys: "vim"}, nil)

	line := runner.acts[0]
	if !strings.Contains(line, "NOT the fixture") {
		t.Errorf("an act delivered while another app held the screen reads clean: %s", line)
	}
	if !strings.Contains(line, "com.stablyai.orca") {
		t.Errorf("the act log does not name what received the keystroke: %s", line)
	}
	// The after reading differs, so both have to survive — a line that kept
	// only the later one would say the fixture was front, which is the
	// opposite of what happened.
	if !strings.Contains(line, "after:") || !strings.Contains(line, "dev.wakil.e2e") {
		t.Errorf("the two readings collapsed into one: %s", line)
	}
}

// Two readings that agree are one sentence, because most acts are ordinary and
// a log nobody can skim is a log nobody reads.
func TestTwoReadingsThatAgreeAreSaidOnce(t *testing.T) {
	front := &Frontmost{PID: 1, BundleID: "dev.wakil.e2e", IsTarget: true,
		TargetHasFocusedWindow: true, FocusedIdentifier: "window.composer"}
	runner := &Runner{beforeLastAct: front, atLastAct: front}
	runner.logAct("x step 1", &Do{Click: "window.send"}, nil)

	if strings.Contains(runner.acts[0], "after:") {
		t.Errorf("two identical readings were printed twice: %s", runner.acts[0])
	}
}

// An act this run had to activate for says so. It succeeded, so nothing else
// in the evidence would record that it was about to be delivered into the
// wrong process.
func TestAnActThisRunHadToActivateForSaysSo(t *testing.T) {
	runner := &Runner{
		beforeLastAct:  &Frontmost{PID: 1, BundleID: "dev.wakil.e2e", IsTarget: true},
		broughtForward: true,
	}
	runner.logAct("x step 6", &Do{Keys: "vim"}, nil)
	if !strings.Contains(runner.acts[0], "brought forward") {
		t.Errorf("a rescued act reads like an ordinary one: %s", runner.acts[0])
	}
}

// TestAnActThatLostTheForegroundSaysSoInTheFailure — the act log carries this
// already, and a reader has to think of opening it. Measured on
// `2c-iii-6-no-orphan.jsonl`: `hotkey cmd+w` went to Teams, the pane did not
// close, and the three failures that followed read as the app ignoring cmd+w.
func TestAnActThatLostTheForegroundSaysSoInTheFailure(t *testing.T) {
	runner := &Runner{
		beforeLastAct: &Frontmost{PID: 1, BundleID: "dev.wakil.e2e", IsTarget: true},
		atLastAct:     &Frontmost{PID: 330, BundleID: "com.microsoft.teams2", IsTarget: false},
	}
	note := runner.foregroundLostNote()
	if !strings.Contains(note, "com.microsoft.teams2") {
		t.Errorf("the failure does not name what took the screen: %q", note)
	}
	if !strings.Contains(note, "may have been delivered there") {
		t.Errorf("the failure does not say what that means for the act: %q", note)
	}
}

// An ordinary act says nothing extra. A note on every failure is a note nobody
// reads, and this one has to mean something when it appears.
func TestAnActThatKeptTheForegroundAddsNothing(t *testing.T) {
	front := &Frontmost{PID: 1, BundleID: "dev.wakil.e2e", IsTarget: true}
	for _, runner := range []*Runner{
		{beforeLastAct: front, atLastAct: front},
		{beforeLastAct: nil, atLastAct: front},
		{beforeLastAct: front, atLastAct: nil},
		// Already not front before the act: the precondition tried and
		// failed, which is a different fact and already in the act log.
		{beforeLastAct: &Frontmost{PID: 9, IsTarget: false}, atLastAct: &Frontmost{PID: 9}},
	} {
		if note := runner.foregroundLostNote(); note != "" {
			t.Errorf("an act that lost nothing said %q", note)
		}
	}
}
