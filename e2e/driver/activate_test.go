package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeOsascript points osascriptPath at a script that prints answer and exits
// with code. The real interpreter needs a window server and a foreground to
// steal, neither of which belongs in `make test`.
func fakeOsascript(t *testing.T, answer string, code int) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "osascript")
	script := fmt.Sprintf("#!/bin/sh\necho %q\nexit %d\n", answer, code)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	previous := osascriptPath
	osascriptPath = path
	t.Cleanup(func() { osascriptPath = previous })
}

// TestActivateWaitsForTheWindowServerRatherThanForTheRequest is the whole
// point of the change it guards. `set frontmost to true` is a request: it was
// measured returning 193ms before the target was actually frontmost, and every
// caller activates in order to deliver a keystroke immediately afterwards. The
// script must therefore POLL, and the poll must be inside the one interpreter
// run — a Go-side loop would spawn an ~190ms process per poll and hide the
// race by being slower than it.
func TestActivateWaitsForTheWindowServerRatherThanForTheRequest(t *testing.T) {
	script := activationScript(4242)

	if !strings.Contains(script, "unix id is 4242") {
		t.Errorf("the script must address the pid it was given:\n%s", script)
	}
	// Addressed by unix id and never by name: a name-addressed activation is
	// ambiguous with the operator's own Wakil, which is the confusion the rest
	// of this harness exists to avoid.
	if strings.Contains(script, "whose name is") {
		t.Errorf("the script must not address a process by name:\n%s", script)
	}
	if !strings.Contains(script, "set frontmost of target to true") {
		t.Errorf("the script must actually activate:\n%s", script)
	}
	// The wait. Without these three the function is the racy one again.
	for _, needed := range []string{"repeat", "if frontmost of target then return \"front\"", "delay"} {
		if !strings.Contains(script, needed) {
			t.Errorf("the script must wait until the target is frontmost, and has no %q:\n%s",
				needed, script)
		}
	}
	// A bounded wait, so a genuinely stuck activation is reported rather than
	// hung on forever.
	if activationPolls*activationPollDelay > 5 {
		t.Errorf("the wait is %.0fs; a stuck activation must be reported, not waited out",
			activationPolls*activationPollDelay)
	}
}

// TestActivateRefusesWhenTheActivationNeverTook. Returning nil here would
// restore the original defect — a caller told the window is front when it is
// not delivers its keystroke into whatever actually holds the screen, and
// reads the refusal that follows as an app defect.
func TestActivateRefusesWhenTheActivationNeverTook(t *testing.T) {
	fakeOsascript(t, "not-front", 0)

	err := Activate(4242)
	if err == nil {
		t.Fatal("an activation that never took must be an error, not a silent success")
	}
	if !strings.Contains(err.Error(), "4242") {
		t.Errorf("the failure must name the pid it could not bring forward: %v", err)
	}
}

// TestActivateAcceptsAnActivationThatTook — the other half, so the test above
// cannot be satisfied by refusing everything.
func TestActivateAcceptsAnActivationThatTook(t *testing.T) {
	fakeOsascript(t, "front", 0)

	if err := Activate(4242); err != nil {
		t.Fatalf("an activation that reported front must succeed: %v", err)
	}
}

// TestActivateReportsAnInterpreterFailure keeps the two failure shapes
// distinct: "the script could not run" and "the script ran and the window
// never came forward" need different things done about them.
func TestActivateReportsAnInterpreterFailure(t *testing.T) {
	fakeOsascript(t, "execution error", 1)

	err := Activate(4242)
	if err == nil {
		t.Fatal("an interpreter failure must be reported")
	}
	if !strings.Contains(err.Error(), "activating pid 4242") {
		t.Errorf("an interpreter failure must be named as one: %v", err)
	}
}
