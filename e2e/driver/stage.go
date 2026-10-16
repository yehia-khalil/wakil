package driver

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// E2EBundleIdentifier is the bundle id a fixture instance runs under.
//
// **Not `dev.wakil.app`, and this is a measured requirement rather than
// hygiene.** Orca refuses EVERY click on a second instance of a bundle id that
// another running instance also claims — by coordinate and by element index
// alike — with `window_not_focused: ... (current: no focused window)`. Its
// click precondition resolves "the focused topmost recipient" through the
// bundle, finds the operator's instance, and correctly declines to aim a
// pointer at a window it cannot establish as the target's.
//
// Measured 2026-09-23, with everything else held constant: the same build,
// same fixture, same coordinates, launched from a copy carrying this id,
// clicks with `ok: true`. Reads, `press-key`, `type-text` and `set-value` were
// never affected — only clicks, which is the whole parity subset.
//
// This is §6.4's rule made structural rather than merely observed. That
// section already says a run must never reach the operator's instance and
// addresses by pid for exactly that reason; a distinct bundle id means the
// two instances cannot be confused by any component, including the ones whose
// resolution the harness does not control. It is the same move the Keychain
// isolation makes: a different keychain FILE, not a naming convention.
const E2EBundleIdentifier = "dev.wakil.e2e"

// StagedBundleName is what every staged copy is called, under whichever
// fixture root made it. Named because it is the one thing a stray from an
// EARLIER run still has in common with this one: the paths differ, and the
// bundle identifier they share is what lets a stray take the foreground.
const StagedBundleName = "WakilE2E.app"

// StageBundle copies bundle into the fixture and gives the copy its own
// bundle id, returning the path to launch.
//
// **The copy is re-signed ad hoc**, because editing `Info.plist` invalidates
// the original ad-hoc signature and macOS then refuses to start the app's
// spawned children — which presents as the isolation guard failing to find a
// Go child, several steps from the cause.
//
// **The copy lives in the fixture**, so teardown removes it with everything
// else, and so two runs can never share one.
func StageBundle(bundle string, fixture Fixture) (string, error) {
	staged := filepath.Join(fixture.Root, StagedBundleName)
	if out, err := exec.Command("cp", "-R", bundle, staged).CombinedOutput(); err != nil {
		return "", fmt.Errorf("staging %s: %w: %s", bundle, err, out)
	}
	plist := filepath.Join(staged, "Contents", "Info.plist")
	set := exec.Command("/usr/libexec/PlistBuddy",
		"-c", "Set :CFBundleIdentifier "+E2EBundleIdentifier, plist)
	if out, err := set.CombinedOutput(); err != nil {
		return "", fmt.Errorf("setting the fixture bundle id: %w: %s", err, out)
	}
	// **Nothing is re-signed, and nothing needs to be.** Wakil.app is never
	// signed AS A BUNDLE: `make-app-bundle.sh` assembles it around a Mach-O
	// that `swift build` already signed ad hoc, and puts SwiftTerm's resource
	// bundle at the .app's top level, where `Bundle.module` looks — which is
	// exactly what makes `codesign` refuse it ("unsealed contents present in
	// the bundle root"). Because no bundle seal exists, editing `Info.plist`
	// invalidates nothing, and the executable's own signature is untouched by
	// the copy.
	return staged, nil
}

// StagedBundleIdentifier reads a bundle's id, so a caller can prove the copy
// is not the operator's before driving it.
func StagedBundleIdentifier(bundle string) (string, error) {
	out, err := exec.Command("/usr/libexec/PlistBuddy",
		"-c", "Print :CFBundleIdentifier",
		filepath.Join(bundle, "Contents", "Info.plist")).Output()
	if err != nil {
		return "", fmt.Errorf("reading %s's bundle id: %w", bundle, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// StagedAgentStubName is the scripted agent's file name inside a fixture.
const StagedAgentStubName = "wakil-e2e-agent"

// StageAgentStub copies the scripted agent into the fixture and returns the
// copy's path, which is what goes on the provider record. An empty stub (no
// agent) stages to nothing.
//
// **Measured 2026-10-08: a stub launched from the checkout is a TCC prompt.**
// The checkout lives under ~/Desktop, a protected folder, and the staged app
// that spawns the stub is ad hoc signed, so its identity changes with every
// `make app-bundle`. The first agent turn after each rebuild raised
// "WakilE2E would like to access files in your Desktop folder" from
// UserNotificationCenter; until it was answered the stub never ran (no
// e2e-agent-log.txt), and the run read as #284. The fixture is under the
// temporary directory, which no prompt guards, so the copy runs everywhere.
func StageAgentStub(stub string, fixture Fixture) (string, error) {
	if stub == "" {
		return "", nil
	}
	dir := filepath.Join(fixture.Root, "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("making %s: %w", dir, err)
	}
	staged := filepath.Join(dir, StagedAgentStubName)
	// `cp -p` keeps the mode, so the copy stays executable.
	if out, err := exec.Command("cp", "-p", stub, staged).CombinedOutput(); err != nil {
		return "", fmt.Errorf("staging the scripted agent %s: %w: %s", stub, err, out)
	}
	return staged, nil
}
