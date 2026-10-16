package wakilcore

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------
// The keychain selector — #301
// ---------------------------------------------------------------------
//
// The seam these tests pin is the one #201 left missing. That commit made
// the Keychain tool an ABSOLUTE path, correctly: the item's ACL trusts
// `/usr/bin/security` by name and a bare `security` off PATH is a
// different application to it. What it also did, unnoticed, was cut the
// only wire the e2e fixture had — the fixture redirects `security` with a
// shim first on PATH, and an absolute path does not consult PATH. From
// #201 until this file every Keychain write out of a SHIPPED Wakil went
// to the operator's login keychain, and the e2e run's own isolation guard
// certified it as isolated because the guard checks PATH.
//
// The fix does not give the tool back. It names the KEYCHAIN instead.

// TestTheKeychainSelectorIsReadInAShippedBinary. This is the asymmetry
// the whole design rests on, so it is asserted rather than described:
// `WAKIL_SECURITY_BINARY` is gated behind `testing.Testing()` and
// `WAKIL_KEYCHAIN` is not.
//
// A test binary cannot observe its own absence of `testing.Testing()`, so
// what is checked here is the source: `keychainSelector` must not consult
// it. That is a real guard and not a tautology — the obvious way to write
// this function is to copy `securityTool` above it, and copying it would
// re-close the door this opens while every behavioural test still passed.
func TestTheKeychainSelectorIsReadInAShippedBinary(t *testing.T) {
	body := functionBody(t, mustRead(t, "credpresence.go"), "keychainSelector")
	if strings.Contains(body, "testing.Testing()") {
		t.Errorf("keychainSelector consults testing.Testing(); it must be read in a "+
			"shipped binary or the e2e fixture cannot isolate the product:\n%s", body)
	}
	if !strings.Contains(body, "os.Getenv(keychainSelectorEnv)") {
		t.Errorf("keychainSelector does not read %s:\n%s", keychainSelectorEnv, body)
	}
}

// TestTheSelectedKeychainIsTheTrailingPositional. `security` scopes
// add/find/delete-generic-password with a trailing `[keychain]`, and that
// positional is the ONLY thing the fixture needs. The tool stays the one
// the ACL names.
func TestTheSelectedKeychainIsTheTrailingPositional(t *testing.T) {
	keychain := filepath.Join(t.TempDir(), "fixture.keychain-db")
	t.Setenv(keychainSelectorEnv, keychain)

	cmd := keychainCommand("find-generic-password", "-s", "wakil:o:r", "-a", keychainAccount)

	if got := cmd.Args[0]; got != string(securityTool()) {
		t.Errorf("argv[0] = %q; want the tool the ACL names, %q", got, securityTool())
	}
	if got := cmd.Args[len(cmd.Args)-1]; got != keychain {
		t.Errorf("last argv = %q; want the selected keychain %q — `security` takes it as a "+
			"trailing positional and nowhere else", got, keychain)
	}
	want := []string{string(securityTool()), "find-generic-password", "-s", "wakil:o:r", "-a", keychainAccount, keychain}
	if strings.Join(cmd.Args, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("argv = %q; want %q", cmd.Args, want)
	}
}

// TestNoKeychainSelectedAppendsNothingAtAll. An empty trailing positional
// is not the same as no positional: `security` would read it as a keychain
// named "", and the operator's default keychain is what "no positional"
// means. A shipped Wakil with nothing set must build the argv it built
// before this seam existed.
func TestNoKeychainSelectedAppendsNothingAtAll(t *testing.T) {
	t.Setenv(keychainSelectorEnv, "")

	cmd := keychainCommand("delete-generic-password", "-s", "wakil:o:r", "-a", keychainAccount)

	want := []string{string(securityTool()), "delete-generic-password", "-s", "wakil:o:r", "-a", keychainAccount}
	if strings.Join(cmd.Args, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("argv = %q; want %q, with no trailing empty positional", cmd.Args, want)
	}
}

// TestEveryKeychainCallIsBuiltByKeychainCommand is the structural half.
//
// **The compiler is the real lock now** — `securityTool` returns a
// `keychainTool`, not a string, so a sixth call site spelling
// `exec.Command(securityTool(), …)` by hand does not build. That was not
// true when this test was written, and it is the better guard: it needs
// no maintenance and it cannot be argued with.
//
// **This stays as the backstop, because the conversion is still
// writable.** `exec.Command(string(securityTool()), …)` compiles and does
// exactly the damage #301 did — writes to whatever keychain is default,
// which during an e2e run is the operator's login keychain. The type
// makes that a thing someone has to type on purpose; this makes it a
// thing they cannot land. Both spellings are matched.
func TestEveryKeychainCallIsBuiltByKeychainCommand(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	// `keychainCommand`'s own body is the one legitimate occurrence — it
	// is the constructor, and it is where the tool and the positional are
	// finally put together. Everything else is a hand-rolled argv.
	handRolled := regexp.MustCompile(`exec\.Command\(\s*(string\()?securityTool\(\)`)
	constructor := functionBody(t, mustRead(t, "credpresence.go"), "keychainCommand")
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		for i, line := range strings.Split(mustRead(t, name), "\n") {
			// A comment naming the pattern is not a call site, and this
			// file's own doc comments quote it on purpose.
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			if handRolled.MatchString(line) && !strings.Contains(constructor, line) {
				t.Errorf("%s:%d builds a Keychain command by hand:\n\t%s\n"+
					"Use keychainCommand, which appends the selected keychain — a hand-rolled "+
					"argv writes to whatever keychain is default, which during an e2e run is "+
					"the operator's login keychain (#301).", name, i+1, strings.TrimSpace(line))
			}
		}
	}
}

// functionBody returns the source text of the named top-level function,
// brace-matched from its opening `{`.
func functionBody(t *testing.T, source, name string) string {
	t.Helper()
	start := strings.Index(source, "\nfunc "+name+"(")
	if start < 0 {
		t.Fatalf("no func %s in the source read", name)
	}
	open := strings.Index(source[start:], "{")
	if open < 0 {
		t.Fatalf("func %s has no body", name)
	}
	depth := 0
	for i := start + open; i < len(source); i++ {
		switch source[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return source[start : i+1]
			}
		}
	}
	t.Fatalf("func %s has an unterminated body", name)
	return ""
}

// mustRead reads one source file of this package, or fails the test.
func mustRead(t *testing.T, name string) string {
	t.Helper()
	source, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return string(source)
}
