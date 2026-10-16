package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// SystemSecurity is the real Keychain CLI the shim forwards to.
const SystemSecurity = "/usr/bin/security"

// Fixture is one run's isolated state: its own HOME, its own temporary
// directory, and its own Keychain reached through a shim on its own PATH.
type Fixture struct {
	Root     string
	Home     string
	TmpDir   string
	BinDir   string
	Keychain string
	// SpeechScript is the scripted microphone every launch carries (2d-ii).
	// Empty means the launch carries none, and then a hold of ⌥ would open
	// the real microphone — which no fixture built by NewFixture does.
	SpeechScript string
	// AnthropicBaseURL is the capacity probe's API: the stub a launch
	// started. Empty makes Env emit a closed port instead.
	AnthropicBaseURL string
}

// NewFixture lays out a fixture under root.
//
// It does **not** create the Keychain file — that is `security create-keychain`,
// a real side effect belonging to the live runner rather than to a function
// unit tests call.
func NewFixture(root string) (Fixture, error) {
	if strings.ContainsAny(root, " \t") {
		return Fixture{}, fmt.Errorf(
			"fixture root %q contains whitespace: the runner verifies its own isolation by "+
				"reading HOME and PATH back out of `ps -Ewww`, which gives no quoting to "+
				"recover a value with a space from", root)
	}
	fixture := Fixture{
		Root:     root,
		Home:     filepath.Join(root, "home"),
		TmpDir:   filepath.Join(root, "tmp"),
		BinDir:   filepath.Join(root, "bin"),
		Keychain: filepath.Join(root, "fixture.keychain-db"),
	}
	for _, dir := range []string{fixture.Home, fixture.TmpDir, fixture.BinDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return Fixture{}, fmt.Errorf("fixture: %w", err)
		}
	}
	shim := filepath.Join(fixture.BinDir, "security")
	if err := os.WriteFile(shim, []byte(SecurityShim(SystemSecurity, fixture.Keychain)), 0o755); err != nil {
		return Fixture{}, fmt.Errorf("fixture: writing the security shim: %w", err)
	}
	// **Every fixture, not only the ones a voice check runs in.** A launch
	// cannot choose per check file (the directory chooses the launch, and
	// nothing inside a check can), and an instance without the script would
	// open the operator's real microphone on the first stray ⌥.
	script, err := writeSpeechScript(root)
	if err != nil {
		return Fixture{}, err
	}
	fixture.SpeechScript = script
	return fixture, nil
}

// Env is the environment a fixture instance is launched with, for
// `open -n --env`.
//
// **The Keychain isolation is TWO things now, and the second is the one
// that reaches the product.** This comment used to say the fixture bin
// going first on PATH "is the whole Keychain isolation", on the strength
// of there being "no absolute-path invocation anywhere in internal/ or
// cmd/". That sentence was true when it was written and false from #201,
// which made `wakilcore` invoke `/usr/bin/security` by absolute path —
// correctly, because the item's ACL trusts that binary by name. An
// absolute path does not consult PATH, so the shim stopped reaching the
// product and nothing said so: the runs stayed green and the first agent
// check hung on macOS asking the operator to authorise a write to their
// own login keychain (#301).
//
// So:
//
//   - `WAKIL_KEYCHAIN` scopes the PRODUCT. `wakilcore` reads it on every
//     Keychain call and passes it as the trailing `[keychain]` positional,
//     keeping the tool the ACL names. This is what isolates `wakil`.
//   - **The shim on PATH stays**, and is not redundant. It covers
//     everything that still resolves `security` by name and that the
//     fixture does not own — `claude` itself above all.
//
// The app's spawned Go children inherit both — PATH measured 2026-09-23,
// wakil-ctx carried it — which is what makes the isolation reach them, and
// `VerifyIsolation` reads both back off the app and off a child before any
// check runs. A launcher that dropped either would write into the
// operator's login keychain, which is why neither is assumed.
//
// **`seeded` is a parameter rather than a field on Fixture** so that no launch
// can forget it: an unseeded fixture opens on the organisation plane, which is
// a legitimate thing to check (`e2e/checks/unseeded/`) and the wrong default for
// everything else, so the choice is made at the call rather than inherited. The
// `e2e` target in the Makefile says why that produces two passes.
//
// **TMPDIR is carried even though the app's own socket ignores it.** It does
// reach the app's process environment and its Go children, so everything
// resolving `$TMPDIR` is isolated by it; Foundation's `temporaryDirectory` is
// not, which the probe measures in §6b and #249 carries.
func (f Fixture) Env(basePATH string, seeded Seeded) []string {
	env := []string{
		"HOME=" + f.Home,
		"TMPDIR=" + f.TmpDir,
		"PATH=" + f.BinDir + ":" + basePATH,
		KeychainSelectorEnv + "=" + f.Keychain,
	}
	// Absent means unset, never the empty string — the rule
	// `childProcessEnvironment` already holds itself to for the org it
	// forwards, and `CurrentOrg` refuses an empty value anyway.
	if seeded.Org != "" {
		env = append(env, "WAKIL_ORG="+seeded.Org)
	}
	// The microphone, replaced (2d-ii). Absent when the fixture has no
	// script, for WAKIL_ORG's reason.
	if f.SpeechScript != "" {
		env = append(env, SpeechScriptEnv+"="+f.SpeechScript)
	}
	// The capacity probe's API (spec amendment 2026-10-11). Always set:
	// a stub when the run started one, else a closed port, so no run can
	// reach api.anthropic.com with a fixture token or spend a real limit.
	base := f.AnthropicBaseURL
	if base == "" {
		base = "http://127.0.0.1:9"
	}
	env = append(env, "WAKIL_ANTHROPIC_BASE_URL="+base)
	return env
}

// SecurityShim is a `security` replacement that scopes every generic-password
// call to one keychain file.
//
// **Why a shim AND a parameter.** Isolation has to be structural, because
// Invariant 4 requires cross-org bleed to be impossible rather than avoided,
// and a fixture run that wrote into the operator's login keychain would break
// that invariant on the operator's own machine. A separate keychain *file* is
// structural; a distinct service-name prefix would only be a convention.
//
// This paragraph once argued a shim was better than a parameter. It is not
// an either/or and #301 is what that cost: the shim reaches only what
// resolves `security` through PATH, and from #201 the product did not.
// `WAKIL_KEYCHAIN` carries the same keychain to the product directly
// (`Env`, and Decision 33). What is left for the shim is everything the
// fixture does NOT own — `claude` above all — which no parameter of
// Wakil's could ever scope.
//
// The keychain is the trailing `[keychain]` positional, which is how the
// `security` CLI scopes these three subcommands. Everything else passes
// through untouched: appending a keychain to `list-keychains` would change
// what it means rather than scope it.
//
// This is an existing repo idiom, not an invention — dbresolve_test.go:228,
// httpclient_test.go:1140, jira_test.go:1338 and secrets_test.go:190 all
// override `security` through PATH the same way.
func SecurityShim(realSecurity, keychain string) string {
	return fmt.Sprintf(`#!/bin/sh
# Generated by the e2e harness. Scopes Wakil's Keychain calls to a throwaway
# keychain so a run cannot touch the operator's login keychain.
case "$1" in
  add-generic-password|find-generic-password|delete-generic-password)
    exec %q "$@" %q ;;
  *)
    exec %q "$@" ;;
esac
`, realSecurity, keychain, realSecurity)
}
