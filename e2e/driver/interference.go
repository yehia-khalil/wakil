package driver

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
)

// recordInterference notes that the fixture stopped being frontmost across
// the act just made (#292): it was the target when the act began and another
// process held the screen when it ended, so the act may have landed there.
func (r *Runner) recordInterference(where string) {
	before, after := r.beforeLastAct, r.atLastAct
	if before == nil || after == nil || !before.IsTarget || after.IsTarget {
		return
	}
	took := after.BundleID
	if took == "" {
		took = fmt.Sprintf("pid %d", after.PID)
	}
	r.interference = append(r.interference, fmt.Sprintf("%s took the foreground during %s", took, where))
}

// interferenceFatal turns a failed check's interference into a fault in the
// run (#292). **Only a failed check**: one that passed was not harmed by it,
// and calling that unsound would fail a run for nothing. A failed one is not
// evidence about the build — red or green — so it is said at the top, the way
// `Session.agentNeverRan` is, rather than as one more line inside a failure;
// and under `make e2e-new` a Fatal run proves nothing, so a stolen foreground
// can never pass for a check that went red on its own.
func interferenceFatal(check string, interference, failures []string) []string {
	if len(interference) == 0 || len(failures) == 0 {
		return nil
	}
	var fatal []string
	for _, line := range interference {
		fatal = append(fatal, fmt.Sprintf(
			"%s failed, and %s — the act may have been delivered outside the fixture, so the "+
				"check's result is not evidence about this build", check, line))
	}
	return fatal
}

// InputEvent is keyboard or pointer events of one type from one poster, seen
// by `axresolve --watch-input` while an act was made. PID 0 is a device: the
// window server stamps the posting process on every synthetic event, and a
// keyboard or a mouse has none.
type InputEvent struct {
	Type  string `json:"type"`
	PID   int    `json:"pid"`
	Path  string `json:"path"`
	Count int    `json:"count"`
}

// watchInput starts watching the input delivered during a keyboard act, and
// returns nil when this act is not watched: no watcher, a watcher that could
// not start, or a mouse act — a click is not where characters the harness
// never sent come from.
func (r *Runner) watchInput(do *Do) func() ([]InputEvent, error) {
	keyboard := do.Keys != "" || do.Type != nil || do.Press != "" || do.Hotkey != ""
	if r.Input == nil || !keyboard {
		return nil
	}
	stop, err := r.Input()
	if err != nil {
		return nil
	}
	return stop
}

// recordOutsideInput notes keyboard or pointer input the harness did not post
// during the act just made (#339): a person, a device, or another process
// touched the machine meanwhile, so the characters a check then reads may not
// be the harness's.
//
// **By who posted each event, never by an idle timer.** H1, measured
// 2026-10-09: `HIDIdleTime` fell from 27.6s to 462ms across a `press Down`
// while a listening tap saw only Orca's helper post anything — the harness's
// own keystroke reset it, the first after a few seconds' quiet, every run.
func (r *Runner) recordOutsideInput(where string, stop func() ([]InputEvent, error)) {
	if stop == nil {
		return
	}
	events, err := stop()
	if err != nil {
		return
	}
	var outside []string
	for _, event := range events {
		if harnessPosted(event) {
			continue
		}
		from := fmt.Sprintf("%s (pid %d)", event.Path, event.PID)
		switch {
		case event.PID == 0:
			from = "a device (pid 0)"
		case event.Path == "":
			from = fmt.Sprintf("pid %d", event.PID)
		}
		outside = append(outside, fmt.Sprintf("%d %s from %s", event.Count, event.Type, from))
	}
	if len(outside) > 0 {
		r.interference = append(r.interference, fmt.Sprintf(
			"keyboard or pointer input the harness did not post arrived during %s: %s",
			where, strings.Join(outside, ", ")))
	}
}

// harnessPosted says whether an event came from one of the harness's own
// actuators: Orca (its computer-use helper lives inside Orca.app) or axresolve.
// **Named by executable, not trusted by default**: an event with no poster
// that can be named is counted against the run.
func harnessPosted(event InputEvent) bool {
	if event.PID == 0 || event.Path == "" {
		return false
	}
	return strings.Contains(event.Path, "/Orca.app/") || filepath.Base(event.Path) == "axresolve"
}

// parseInputReply reads `axresolve --watch-input`'s final line.
func parseInputReply(out []byte) ([]InputEvent, error) {
	var reply struct {
		OK    bool         `json:"ok"`
		Input []InputEvent `json:"input"`
		Error *OrcaError   `json:"error"`
	}
	if err := json.Unmarshal(out, &reply); err != nil {
		return nil, fmt.Errorf("the input watcher's reply could not be read (%w): %s", err, firstLine(out))
	}
	if !reply.OK {
		return nil, fmt.Errorf("the input watcher refused: %v", reply.Error)
	}
	return reply.Input, nil
}
