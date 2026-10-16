package driver

import (
	"strings"
	"testing"
)

func fixtureFor(t *testing.T) Fixture {
	t.Helper()
	return Fixture{Root: "/f", Home: "/f/home", TmpDir: "/f/tmp", BinDir: "/f/bin",
		Keychain: "/f/fixture.keychain-db"}
}

// isolated is the environment a properly isolated process reads back: the
// fixture HOME, the shim first on PATH, and — since #301 — the fixture
// keychain named outright, which is the channel the shipped product
// actually reads.
func isolated() map[string]string {
	return map[string]string{
		"HOME":           "/f/home",
		"PATH":           "/f/bin:/usr/bin",
		"WAKIL_KEYCHAIN": "/f/fixture.keychain-db",
	}
}

// withEnv returns the isolated environment with one variable changed.
func withEnv(name, value string) map[string]string {
	env := isolated()
	if value == "" {
		delete(env, name)
		return env
	}
	env[name] = value
	return env
}

func TestVerifyIsolationAcceptsAProperlyIsolatedInstance(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		isolated(),
		isolated())
	if err != nil {
		t.Fatalf("want isolation to hold, got %v", err)
	}
}

func TestVerifyIsolationRefusesAnInstanceOnTheRealHome(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		withEnv("HOME", "/Users/operator"),
		withEnv("HOME", "/Users/operator"))
	if err == nil {
		t.Fatal("want a refusal: that is the operator's instance")
	}
}

func TestVerifyIsolationRefusesAPathThatBypassesTheShim(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		map[string]string{"HOME": "/f/home", "PATH": "/usr/bin:/f/bin"},
		map[string]string{"HOME": "/f/home", "PATH": "/usr/bin:/f/bin"})
	if err == nil {
		t.Fatal("want a refusal: /usr/bin/security would win and write to the login keychain")
	}
}

// THE POINT OF THIS FILE. An absent child is not a passing check. The Keychain
// isolation is a shim on PATH, and the writes that matter come from the Go
// children — so "I could not find a child to inspect" must be red, exactly as
// "no check ran" is red. Silence is not success, here least of all.
func TestVerifyIsolationRefusesWhenTheChildWasNeverSeen(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		isolated(),
		nil)
	if err == nil {
		t.Fatal("want a refusal when no child environment could be read")
	}
	if !strings.Contains(err.Error(), "child") {
		t.Fatalf("error must say what was missing, got %q", err)
	}
}

func TestVerifyIsolationRefusesAChildWithNoPathAtAll(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		isolated(),
		map[string]string{})
	if err == nil {
		t.Fatal("want a refusal when the child carries no PATH")
	}
}

// The child must be proved OURS before its PATH means anything. `pgrep` on the
// bundle path finds any instance's children — a concurrent run's, or one left
// by an earlier run — and a foreign child's PATH says nothing about this
// instance's Keychain isolation.
func TestVerifyIsolationRefusesAChildFromAnotherInstance(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		isolated(),
		withEnv("HOME", "/Users/operator"))
	if err == nil {
		t.Fatal("want a refusal: that child belongs to another instance")
	}
	if !strings.Contains(err.Error(), "/Users/operator") {
		t.Fatalf("refusal must name the HOME it saw, got %q", err)
	}
}

func TestVerifyIsolationAcceptsAChildOnTheFixtureHome(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		isolated(),
		isolated())
	if err != nil {
		t.Fatalf("want isolation to hold, got %v", err)
	}
}

// ---------------------------------------------------------------------
// The keychain the product actually reads — #301
// ---------------------------------------------------------------------
//
// Between #201 and #301 this guard certified every run as isolated while
// the shipped `wakil` bypassed the channel it checks. The PATH shim was
// real and the check on it was honest; the product had simply stopped
// resolving `security` through PATH, so the guard was reading a variable
// nothing downstream consulted. What that cost was not a red run — it was
// a green one, thirteen minutes into an agent check, with macOS asking
// the operator to authorise a write to their login keychain.
//
// So PATH is no longer sufficient evidence, and these two tests are what
// says so.

func TestVerifyIsolationRefusesAnInstanceThatNamesNoKeychain(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		withEnv("WAKIL_KEYCHAIN", ""),
		isolated())
	if err == nil {
		t.Fatal("want a refusal: with no keychain named, the shipped binary's " +
			"absolute-path `security` writes to the operator's login keychain")
	}
	if !strings.Contains(err.Error(), "WAKIL_KEYCHAIN") {
		t.Fatalf("refusal must name the variable that was missing, got %q", err)
	}
}

func TestVerifyIsolationRefusesAnInstanceOnAnotherKeychain(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		withEnv("WAKIL_KEYCHAIN", "/Users/operator/Library/Keychains/login.keychain-db"),
		isolated())
	if err == nil {
		t.Fatal("want a refusal: that is the operator's keychain")
	}
}

// The child is where the writes come from, so the child is where this
// matters most — and it is the case the PATH check already made this file
// argue for once.
func TestVerifyIsolationRefusesAChildThatNamesNoKeychain(t *testing.T) {
	err := VerifyIsolation(fixtureFor(t),
		isolated(),
		withEnv("WAKIL_KEYCHAIN", ""))
	if err == nil {
		t.Fatal("want a refusal: a Keychain write from that child reaches the login keychain")
	}
	if !strings.Contains(err.Error(), "child") {
		t.Fatalf("refusal must say it was the child, got %q", err)
	}
}

// A fixture with no keychain of its own cannot prove anything about one,
// and it is a programming error here rather than an isolation failure —
// but it must still be red, because the alternative is a guard that
// passes when both sides are empty.
func TestVerifyIsolationRefusesAFixtureWithNoKeychain(t *testing.T) {
	fixture := fixtureFor(t)
	fixture.Keychain = ""
	err := VerifyIsolation(fixture, withEnv("WAKIL_KEYCHAIN", ""), withEnv("WAKIL_KEYCHAIN", ""))
	if err == nil {
		t.Fatal("want a refusal: a fixture with no keychain isolates nothing")
	}
}
