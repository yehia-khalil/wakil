package driver

import (
	"fmt"
	"os/exec"
	"strings"
)

// LockKey is the window server's own name for the fact, inside the console
// session dictionary `ioreg` exposes under the IORegistry root.
const LockKey = "CGSSessionScreenIsLocked"

// ScreenLocked reports whether this Mac's screen is locked.
//
// **A locked screen is not a slow window, and telling them apart is worth a
// precondition of its own.** #284, measured 2026-09-25: three consecutive runs
// died with `pid N never presented a readable window within 30s: app 'Wakil'
// has no accessibility window; make sure the app has a visible window`. The
// app was healthy — running, `visible`, all three Go children up — and the
// screen had been locked for twelve hours. AppKit presents no window to the
// accessibility API behind a lock, so that message named the app for something
// the session had done, and cost thirty seconds a run to say it.
//
// **Read from `ioreg` rather than through cgo.** The value lives in
// `CGSessionCopyCurrentDictionary`, which is CoreGraphics and would make this
// package the only one in the harness that needs a C toolchain and a
// framework link — for one boolean that a subprocess already prints.
//
// An error here is the caller's to ignore: a harness that refused to run
// because it could not determine the lock state would be strictly worse than
// one that tried and reported what it found.
func ScreenLocked() (bool, error) {
	out, err := exec.Command("ioreg", "-n", "Root", "-d1", "-a").Output()
	if err != nil {
		return false, fmt.Errorf("asking ioreg whether the screen is locked: %w", err)
	}
	return screenLockedIn(string(out)), nil
}

// screenLockedIn reads the answer out of an `ioreg -a` plist.
//
// **Text, not a plist decode, because Go has no plist in its standard library**
// and the alternative is a dependency for one boolean. The shape read here is
// the only one `ioreg -a` emits: a `<key>` element followed by its value
// element.
//
// **Any locked session counts, which is deliberately conservative.** Fast user
// switching can put more than one session dictionary in this list, and telling
// ours apart from another user's means tracking which dictionary each key sits
// in. The cost of being wrong is asymmetric: a run refused on a locked screen
// somebody else left behind says exactly what to go and check, and a run
// allowed onto a locked screen spends thirty seconds blaming the app.
func screenLockedIn(plist string) bool {
	key := "<key>" + LockKey + "</key>"
	for rest := plist; ; {
		at := strings.Index(rest, key)
		if at < 0 {
			return false
		}
		rest = rest[at+len(key):]
		if strings.HasPrefix(strings.TrimSpace(rest), "<true/>") {
			return true
		}
	}
}

// RefuseIfScreenLocked is the precondition every launch runs first.
//
// **Before the fixture, the seed and the staged bundle**, the rule
// `ResolveAgentFixture` already holds to: this is knowable in milliseconds,
// and discovering it after a staged copy of Wakil.app costs the copy and
// thirty seconds of polling for a window that cannot exist.
//
// **It refuses rather than waits.** Nothing in a headless run unlocks a Mac,
// so a launch that waited would be waiting on a human — and `e2e.md`'s rule
// against retrying a check into green applies twice over to retrying the whole
// suite into green.
func RefuseIfScreenLocked() error {
	locked, err := ScreenLocked()
	if err != nil {
		return nil
	}
	return refusalFor(locked)
}

// refusalFor is the sentence, separated from the reading so the sentence can
// be tested on a machine whose screen is in either state.
func refusalFor(locked bool) error {
	if !locked {
		return nil
	}
	return fmt.Errorf(
		"this Mac's screen is locked, so no window will appear and no check can run: AppKit " +
			"presents nothing to the accessibility API behind a lock, and the app would be " +
			"blamed for it (#284). Unlock the screen and run again — and note that a run long " +
			"enough to reach the idle timer can be locked out partway through")
}
