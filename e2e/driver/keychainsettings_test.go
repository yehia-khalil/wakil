package driver

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// **A fixture keychain must not relock itself mid-run.**
//
// `security create-keychain` returns one set to `lock-on-sleep timeout=300s`.
// A suite that takes longer than that between the launch and a turn — or a
// machine that sleeps — finds the keychain locked, and the window's credential
// lookup fails for a reason that has nothing to do with the check. That is
// #284's most expensive shape: an agent that will not start looks identical
// however it was caused.
//
// This drives the real `security`, because the default it is asserting about
// is `security`'s and a fake would only restate this test's own belief.
func TestTheFixtureKeychainDoesNotRelockItself(t *testing.T) {
	if _, err := os.Stat(SystemSecurity); err != nil {
		t.Skipf("no %s on this machine: %v", SystemSecurity, err)
	}
	root, err := os.MkdirTemp("/tmp", "wakil-keychain")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	fixture, err := NewFixture(root)
	if err != nil {
		t.Fatal(err)
	}
	launch := Launch{Fixture: fixture}
	if err := launch.makeKeychain(); err != nil {
		t.Fatalf("making the fixture keychain: %v", err)
	}
	defer func() {
		_ = exec.Command(SystemSecurity, "delete-keychain", fixture.Keychain).Run()
	}()

	out, err := exec.Command(SystemSecurity, "show-keychain-info", fixture.Keychain).CombinedOutput()
	if err != nil {
		t.Fatalf("reading the keychain's settings: %v: %s", err, out)
	}
	settings := strings.TrimSpace(string(out))
	if strings.Contains(settings, "timeout=") {
		t.Errorf("the fixture keychain relocks itself on a timer, so a run longer than it "+
			"would lose its credential mid-flight and report an agent that would not start: %s",
			settings)
	}
	if strings.Contains(settings, "lock-on-sleep") {
		t.Errorf("the fixture keychain locks when the machine sleeps, which makes an overnight "+
			"or unattended run fail for a reason no check asserts: %s", settings)
	}
	if filepath.Base(fixture.Keychain) == "" {
		t.Fatal("the fixture named no keychain")
	}
}
