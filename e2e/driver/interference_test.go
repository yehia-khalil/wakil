package driver

import (
	"fmt"
	"strings"
	"testing"
)

// #292: the fixture was frontmost when an act began and another app was when
// it ended. The act went there, and the check's red was about Teams, not the
// branch. It is now a fault in the RUN, like an agent that never launched —
// and under `make e2e-new`, where red is wanted, a red bought by a stolen
// foreground must never count as proof.

func TestAnActThatLostTheForegroundIsRecordedAsInterference(t *testing.T) {
	runner := &Runner{
		beforeLastAct: &Frontmost{PID: 1, BundleID: "dev.wakil.e2e", IsTarget: true},
		atLastAct:     &Frontmost{PID: 330, BundleID: "com.microsoft.teams2", IsTarget: false},
	}
	runner.recordInterference("no-orphan.jsonl step 7")
	if len(runner.interference) != 1 ||
		!strings.Contains(runner.interference[0], "com.microsoft.teams2 took the foreground during no-orphan.jsonl step 7") {
		t.Fatalf("interference = %v", runner.interference)
	}
}

func TestAnActThatKeptTheForegroundIsNotInterference(t *testing.T) {
	front := &Frontmost{PID: 1, BundleID: "dev.wakil.e2e", IsTarget: true}
	runner := &Runner{beforeLastAct: front, atLastAct: front}
	runner.recordInterference("x step 1")
	if len(runner.interference) != 0 {
		t.Fatalf("interference = %v", runner.interference)
	}
}

func TestInterferenceInAFailedCheckIsAFaultInTheRun(t *testing.T) {
	fatal := interferenceFatal("no-orphan.jsonl",
		[]string{"com.microsoft.teams2 took the foreground during no-orphan.jsonl step 7"},
		[]string{"no-orphan.jsonl step 8: pane is still open"})
	if len(fatal) != 1 || !strings.Contains(fatal[0], "no-orphan.jsonl failed, and com.microsoft.teams2 took the foreground") ||
		!strings.Contains(fatal[0], "not evidence about this build") {
		t.Fatalf("fatal = %v", fatal)
	}
}

func TestInterferenceInACheckThatPassedChangesNothing(t *testing.T) {
	if fatal := interferenceFatal("x.jsonl", []string{"something took the foreground"}, nil); len(fatal) != 0 {
		t.Fatalf("a check that passed anyway was not harmed by it: %v", fatal)
	}
}

// #339: characters the harness never sent arrived with the fixture frontmost.
//
// H1, measured 2026-10-09: the first version read `HIDIdleTime`, and Orca's
// OWN keystrokes reset it — 27.6s idle before `press Down`, 462ms after it,
// while a listening event tap saw nothing but Orca's helper post anything. So
// it voided every `make e2e-new` run with a keystroke in it. An idle timer
// cannot say who touched the machine; the event itself can. The runner now
// watches the events delivered during a keyboard act and counts only those no
// harness actuator posted.

const orcaHelper = "/Applications/Orca.app/Contents/Resources/Orca Computer Use.app/Contents/MacOS/orca-computer-use-macos"

// watching returns a watcher that reports events when stopped, and counts how
// many acts it was asked to watch.
func watching(started *int, events ...InputEvent) func() (func() ([]InputEvent, error), error) {
	return func() (func() ([]InputEvent, error), error) {
		*started++
		return func() ([]InputEvent, error) { return events, nil }, nil
	}
}

func TestKeystrokesTheHarnessPostedAreNotInterference(t *testing.T) {
	started := 0
	runner := &Runner{Input: watching(&started,
		InputEvent{Type: "keyDown", PID: 34482, Path: orcaHelper, Count: 1},
		InputEvent{Type: "keyUp", PID: 34482, Path: orcaHelper, Count: 1},
		InputEvent{Type: "flagsChanged", PID: 812, Path: "/Users/me/wakil/e2e/bin/axresolve", Count: 1})}
	stop := runner.watchInput(&Do{Press: "Down"})
	runner.recordOutsideInput("3a-i-git-keys.jsonl step 10", stop)
	if started != 1 || len(runner.interference) != 0 {
		t.Fatalf("started %d, interference = %v", started, runner.interference)
	}
}

func TestInputFromADeviceDuringAKeyboardActIsInterference(t *testing.T) {
	started := 0
	runner := &Runner{Input: watching(&started,
		InputEvent{Type: "keyDown", PID: 34482, Path: orcaHelper, Count: 1},
		InputEvent{Type: "keyDown", PID: 0, Count: 3})}
	stop := runner.watchInput(&Do{Keys: "touch marker"})
	runner.recordOutsideInput("no-orphan.jsonl step 5", stop)
	if len(runner.interference) != 1 ||
		!strings.Contains(runner.interference[0],
			"keyboard or pointer input the harness did not post arrived during no-orphan.jsonl step 5") ||
		!strings.Contains(runner.interference[0], "3 keyDown from a device (pid 0)") ||
		strings.Contains(runner.interference[0], "orca-computer-use-macos") {
		t.Fatalf("interference = %v", runner.interference)
	}
}

func TestInputAnotherProcessPostedIsInterference(t *testing.T) {
	started := 0
	runner := &Runner{Input: watching(&started,
		InputEvent{Type: "mouseMoved", PID: 4410, Path: "/usr/local/bin/jiggler", Count: 2})}
	stop := runner.watchInput(&Do{Type: &TypeInto{Into: "api.path", Text: "/v1"}})
	runner.recordOutsideInput("api-hole.jsonl step 10", stop)
	if len(runner.interference) != 1 ||
		!strings.Contains(runner.interference[0], "2 mouseMoved from /usr/local/bin/jiggler (pid 4410)") {
		t.Fatalf("interference = %v", runner.interference)
	}
}

func TestAMouseActIsNotWatchedForOutsideInput(t *testing.T) {
	started := 0
	runner := &Runner{Input: watching(&started, InputEvent{Type: "keyDown", PID: 0, Count: 1})}
	stop := runner.watchInput(&Do{Click: "landing.row.open:db"})
	runner.recordOutsideInput("x step 1", stop)
	if started != 0 || len(runner.interference) != 0 {
		t.Fatalf("started %d, interference = %v", started, runner.interference)
	}
}

func TestNoWatcherWatchesNothing(t *testing.T) {
	runner := &Runner{}
	stop := runner.watchInput(&Do{Keys: "x"})
	runner.recordOutsideInput("x step 1", stop)
	if len(runner.interference) != 0 {
		t.Fatalf("interference = %v", runner.interference)
	}
}

func TestAWatcherThatCannotStartIsNotInterference(t *testing.T) {
	runner := &Runner{Input: func() (func() ([]InputEvent, error), error) {
		return nil, fmt.Errorf("tap_unavailable")
	}}
	stop := runner.watchInput(&Do{Press: "Return"})
	runner.recordOutsideInput("x step 1", stop)
	if len(runner.interference) != 0 {
		t.Fatalf("interference = %v", runner.interference)
	}
}

func TestTheWatchersReplyIsRead(t *testing.T) {
	events, err := parseInputReply([]byte(`{"input":[{"count":2,"path":"` + orcaHelper +
		`","pid":34482,"type":"keyDown"},{"count":1,"pid":0,"type":"mouseMoved"}],"ok":true}`))
	if err != nil || len(events) != 2 || events[0].Path != orcaHelper || events[1].PID != 0 || events[0].Count != 2 {
		t.Fatalf("events = %+v, err = %v", events, err)
	}
	if _, err := parseInputReply([]byte(`{"ok":false,"error":{"code":"tap_unavailable","message":"no tap"}}`)); err == nil ||
		!strings.Contains(err.Error(), "no tap") {
		t.Fatalf("a refusal must be an error: %v", err)
	}
}
