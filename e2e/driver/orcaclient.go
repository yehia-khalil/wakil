package driver

import (
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
)

// Orca runs the Orca CLI. **It never CLICKS**, and since #253 it does type.
//
// The clicking moved to the resolver on 2026-09-23, because Orca refuses to
// click the fixture at all — the measurements are in
// e2e/axresolve/main.swift's header. This comment said "reads and never
// writes" until #253, and that was the accurate description of the moment
// rather than the rule: the probe recorded in the same session that
// `press-key`, `type-text` and `set-value` were NEVER affected by the refusal
// — only clicks were.
//
// **The keyboard has to come back here, because nothing else can send one.**
// A terminal pane is a PTY behind a canvas: it carries no accessibility
// identifier, `AXPress` means nothing to it, and `set-value` on a shell is
// meaningless. Six of 2c-iii's seven mechanizable checks are unwritable
// without keystrokes.
//
// **This is not the second click channel the original ruling feared.** That
// ruling was about two ways to press the same named control, where a check
// could pass through one while the other was broken. There is still exactly
// one of those, and it is the resolver. Keystrokes address keyboard focus,
// which the resolver cannot reach at all, so these are a channel with no
// second implementation rather than a duplicate of one.
type Orca struct {
	Exe string
}

// GetAppState reads one instance's accessibility state.
//
// **Addressed by pid, never by bundle id.** With two Wakils running,
// `list-windows --app dev.wakil.app` returned only the operator's window, with
// no error and no indication a second existed (probe §1). A check that reached
// the operator's window would be driving their live credentials, and nothing
// in the reply would say so.
//
// A fresh call here is also the precondition for every index-based action:
// Orca refuses one that is not preceded by a snapshot for that app and window
// with `element_not_found: element indexes require a fresh get-app-state
// snapshot for this app/window`. So the driver never caches an index.
func (o Orca) GetAppState(pid int) (Response, error) {
	return o.run("computer", "get-app-state", "--app", pidSelector(pid), "--no-screenshot", "--json")
}

func pidSelector(pid int) string { return "pid:" + strconv.Itoa(pid) }

// run executes one Orca command and parses its reply.
//
// A non-zero exit is **not** itself an error: Orca reports a structured
// failure — app_not_found, element_not_found — as a well-formed payload with
// ok:false, and a caller acts on those codes differently. What is an error is
// output that does not parse at all, which is how the unreadable-symlink
// failure arrives: on stdout, with exit 0.
func (o Orca) run(args ...string) (Response, error) {
	command := exec.Command(o.Exe, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	runErr := command.Run()

	response, parseErr := ParseResponse(stdout.Bytes())
	if parseErr != nil {
		if runErr != nil {
			return Response{}, fmt.Errorf("orca %v failed (%w) and its output was unusable: %w", args, runErr, parseErr)
		}
		return Response{}, fmt.Errorf("orca %v: %w", args, parseErr)
	}
	return response, nil
}

// Capture reads the state WITH a screenshot, for evidence.
//
// Every other read passes --no-screenshot, because a capture per assertion
// would cost a file per assertion and prove nothing. This one is called when
// a check has already failed.
func (o Orca) Capture(pid int) (Response, error) {
	return o.run("computer", "get-app-state", "--app", pidSelector(pid), "--json")
}

// TypeText types literal text at whatever holds keyboard focus.
//
// **Addressed by pid, like every other call here, and it matters more.** This
// channel carries WRITES: with two Wakils running, a bundle-id selector
// silently resolves to one of them, and a command typed into the operator's
// own shell is the worst thing this harness could do.
//
// **`--restore-window`, and it took a flake to earn it.** The first version
// left the flag off, on the argument that whether the right window receives a
// keystroke is a fact a check must establish rather than one the driver
// arranges behind it. In practice that made every keystroke depend on ambient
// focus: measured, a run with something else frontmost refused twelve acts
// with `window_not_focused: keyboard input requires the target Wakil window
// to be focused`, in a check that had passed a dozen times before.
//
// The argument was answering the wrong risk. The danger is a keystroke
// reaching the WRONG window, and the flag cannot cause that — it restores the
// window of the pid this call already names, so it can only ever bring the
// fixture forward. Which PANE has keyboard focus is still the check's own
// business, established by clicking it and asserted by reading back what was
// typed.
//
// It is also what makes the foreground cost honest: keystrokes take the
// screen, and now they say so instead of failing when they do not get it.
func (o Orca) TypeText(pid int, text string) (Response, error) {
	return o.run("computer", "type-text", "--app", pidSelector(pid),
		"--text", text, "--restore-window", "--no-screenshot", "--json")
}

// ClickAt sends a real mouse click at a point in screen coordinates.
//
// **The only way to focus a text field.** `AXPress` on one returns AXError
// -25206 — the action is unsupported — and `set-value` moves no focus. What a
// mouse does, and what this does, is land a click on the element itself.
//
// **It takes the foreground**, as every real click does. The coordinates come
// from the resolver's own frame for the element, read immediately before the
// click, because a point computed from an older tree can land on whatever has
// since moved under it.
func (o Orca) ClickAt(pid int, x, y float64) (Response, error) {
	return o.run("computer", "click", "--app", pidSelector(pid),
		"--x", strconv.Itoa(int(x)), "--y", strconv.Itoa(int(y)),
		"--restore-window", "--no-screenshot", "--json")
}

// PressKey sends one named key — Return, Escape, Tab, Left, PageUp.
func (o Orca) PressKey(pid int, key string) (Response, error) {
	return o.run("computer", "press-key", "--app", pidSelector(pid),
		"--key", key, "--restore-window", "--no-screenshot", "--json")
}

// Hotkey sends a modifier chord.
//
// `ctrl+c` is the one 2c-iii needs, and it is a chord rather than a key
// precisely because the PTY has to receive an interrupt and not the letter c.
func (o Orca) Hotkey(pid int, combination string) (Response, error) {
	return o.run("computer", "hotkey", "--app", pidSelector(pid),
		"--key", combination, "--restore-window", "--no-screenshot", "--json")
}
