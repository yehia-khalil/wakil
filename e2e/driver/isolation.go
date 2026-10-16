package driver

import (
	"fmt"
	"strings"
)

// VerifyIsolation decides whether a launched instance is really isolated from
// the operator's, given the environment read back off the app and off one of
// the Go children it spawned.
//
// **An absent child is a refusal, not a pass.** The Keychain writes that
// matter come from the Go children — so "no child could be inspected" proves
// nothing and must be red, exactly as "no check ran" is red. This function
// exists because the first version of the launcher returned success in that
// case: the guard could pass vacuously, which is the precise failure the
// whole harness is built to prevent.
//
// **Two channels are checked, and #301 is why there are two.** The shim on
// PATH is the older one and still covers everything that resolves `security`
// by name — `claude` itself, and any tool the fixture does not own.
// `WAKIL_KEYCHAIN` is the one the PRODUCT reads: since #201 `wakilcore`
// invokes `/usr/bin/security` by absolute path, because the item's ACL
// trusts that binary and no other, and an absolute path does not consult
// PATH.
//
// Between those two commits this function passed every run while checking a
// variable nothing downstream consulted. It was not wrong about PATH; it was
// reading the wrong channel, which is a worse failure than being red and is
// invisible in exactly the same way a vacuous pass is. Both are checked now,
// and neither alone is sufficient evidence.
func VerifyIsolation(fixture Fixture, app, child map[string]string) error {
	if app["HOME"] != fixture.Home {
		return fmt.Errorf("the instance has HOME=%q, want the fixture %q — refusing to drive it, "+
			"because an instance on the real HOME is the operator's", app["HOME"], fixture.Home)
	}
	if err := shimWins(app["PATH"], fixture.BinDir); err != nil {
		return fmt.Errorf("the instance's %w", err)
	}
	if err := keychainNamed(app[KeychainSelectorEnv], fixture.Keychain); err != nil {
		return fmt.Errorf("the instance %w", err)
	}
	if len(child) == 0 {
		return fmt.Errorf(
			"no Go child of the instance could be inspected, so the Keychain isolation is " +
				"unproven — the shim lives on PATH and it is the children that write secrets")
	}
	// The child must be proved OURS before its PATH means anything. `pgrep` on
	// the bundle path finds any instance's children — a concurrent run's, or
	// one an earlier run left behind — and a foreign child's PATH says nothing
	// about this instance.
	if child["HOME"] != fixture.Home {
		return fmt.Errorf("the Go child inspected has HOME=%q, not the fixture %q, so it "+
			"belongs to another instance and proves nothing about this one",
			child["HOME"], fixture.Home)
	}
	if err := shimWins(child["PATH"], fixture.BinDir); err != nil {
		return fmt.Errorf("the spawned Go child's %w — a Keychain write from it would reach "+
			"the operator's login keychain", err)
	}
	if err := keychainNamed(child[KeychainSelectorEnv], fixture.Keychain); err != nil {
		return fmt.Errorf("the spawned Go child %w — and the child is where the writes "+
			"come from", err)
	}
	return nil
}

// KeychainSelectorEnv is the variable `wakilcore` reads to decide which
// keychain file every one of its `security` calls is scoped to. It is
// spelled here as well as there because the harness has no import path into
// `internal/`, and the two spellings are held together by
// `TestTheHarnessAndTheProductSpellTheSelectorTheSameWay`.
const KeychainSelectorEnv = "WAKIL_KEYCHAIN"

// keychainNamed reports whether an inspected process was told to operate on
// the fixture's keychain and no other.
//
// **Unset is a refusal rather than a default.** An unset selector is exactly
// how a shipped Wakil addresses the operator's login keychain, so "nothing
// was set" is the failure case in full, not a missing detail.
func keychainNamed(selected, keychain string) error {
	if keychain == "" {
		return fmt.Errorf("was checked against a fixture that has no keychain of its own, " +
			"so nothing is proven — this is a harness bug, and it is red because a guard " +
			"that passes when both sides are empty is the vacuous pass this file exists to refuse")
	}
	if selected == "" {
		return fmt.Errorf("carries no %s, so its `security` calls go to the DEFAULT keychain — "+
			"which is the operator's login keychain. Since #201 the product invokes "+
			"/usr/bin/security by absolute path, so the shim on PATH does not reach it and "+
			"PATH alone proves nothing (#301)", KeychainSelectorEnv)
	}
	if selected != keychain {
		return fmt.Errorf("has %s=%q, want the fixture's %q — a run scoped to any other "+
			"keychain is writing somewhere this harness does not own",
			KeychainSelectorEnv, selected, keychain)
	}
	return nil
}

// shimWins reports whether binDir is early enough in path to win resolution.
func shimWins(path, binDir string) error {
	if path == "" {
		return fmt.Errorf("PATH is empty, so the `security` shim cannot be reached at all")
	}
	if !strings.HasPrefix(path, binDir+":") && path != binDir {
		return fmt.Errorf("PATH is %q, which does not start with the fixture bin %q, so "+
			"/usr/bin/security would win and the shim would be bypassed", path, binDir)
	}
	return nil
}
