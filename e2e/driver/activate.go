package driver

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// osascriptPath is the AppleScript interpreter. A variable rather than a
// constant so a test can point it at a fake and assert what Activate DECIDES
// about an activation that did not take, which is the half that can regress
// without a window server.
var osascriptPath = "/usr/bin/osascript"

// activationPolls and activationPollDelay bound the wait below: 2 seconds,
// which is an order of magnitude more than the ~200ms measured and still short
// enough that a genuinely stuck activation is reported rather than hung on.
const (
	activationPolls     = 100
	activationPollDelay = 0.02
)

// activationScript brings a process forward AND WAITS UNTIL IT IS ACTUALLY
// FRONTMOST, answering "front" or "not-front".
//
// **The wait is the whole point, and its absence was a measured race.**
// `set frontmost to true` is a REQUEST to the window server, not a
// transaction: measured 2026-09-25, `osascript` returned 193ms after being
// asked and the target was still not frontmost — it arrived somewhere after
// that. Every caller here activates in order to deliver a keystroke next, and
// a keystroke sent into that gap goes wherever the foreground still is. So
// Activate used to return "done" at the one moment its postcondition was
// reliably false.
//
// **Why the loop is inside the AppleScript rather than in Go.** Polling from
// Go would spawn an `osascript` per poll, at ~190ms each — slower than the
// thing being waited for, and enough on its own to hide the race by accident.
// One process that polls internally costs one spawn and answers in tens of
// milliseconds.
func activationScript(pid int) string {
	return fmt.Sprintf(`tell application "System Events"
	set target to first process whose unix id is %d
	set frontmost of target to true
	repeat %d times
		if frontmost of target then return "front"
		delay %v
	end repeat
end tell
return "not-front"`, pid, activationPolls, activationPollDelay)
}

// Activate brings the fixture instance to the front and returns only once it
// IS in front.
//
// **Keystrokes need it and Orca's own `--restore-window` is not enough.**
// Measured 2026-09-24: with the flag set, Orca still refused four acts in a
// row with `window_not_focused: ... --restore-window was requested but the
// target is still not focused`. An app started with `open -n` does not
// reliably become frontmost, and three checks in the same run had passed
// moments earlier — so this is a race, which is the worst kind of thing to
// leave in an instrument.
//
// **`System Events`, addressed by unix id.** It is the one mechanism that
// activates a process by PID rather than by name on this machine; a
// name-addressed activation would be ambiguous with the operator's own Wakil,
// which is the confusion every other part of this harness is built to avoid.
//
// **An activation that never took is a failure, not a delay.** Returning nil
// after the wait expired would restore exactly the bug the wait exists to fix,
// only later; a caller that is told "front" and is not is worse off than one
// told nothing. So "not-front" is an error naming what actually held the
// screen.
//
// A failure is returned rather than swallowed: it means the keystrokes that
// follow will be refused, and saying so here names the cause instead of
// leaving four identical refusals to be read backwards.
func Activate(pid int) error {
	out, err := exec.Command(osascriptPath, "-e", activationScript(pid)).CombinedOutput()
	answer := strings.TrimSpace(string(out))
	if err != nil {
		return fmt.Errorf("activating pid %d: %w: %s", pid, err, answer)
	}
	if answer != "front" {
		return fmt.Errorf(
			"pid %d was asked to come forward and had not %.0fs later — %s still holds the screen",
			pid, activationPolls*activationPollDelay, describeFrontmost())
	}
	return nil
}

// FrontmostPID reports the pid of the frontmost application, so a caller can
// say what took the screen instead of only that it was not the fixture.
//
// **The slow path, for a refusal.** It shells out to osascript, so it costs
// tens of milliseconds and is called only when an act has already been
// refused. An act that went THROUGH reports the same fact — and more of it —
// in its own reply; see Frontmost.
func FrontmostPID() (int, error) {
	out, err := exec.Command(osascriptPath, "-e",
		`tell application "System Events" to get unix id of first process whose frontmost is true`).Output()
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}
