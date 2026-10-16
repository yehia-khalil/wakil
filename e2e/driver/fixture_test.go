package driver

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The shim is executed, not merely string-compared: what matters is the argv
// the real `security` would receive, and only running it shows that.
func runShim(t *testing.T, args ...string) string {
	t.Helper()
	dir := t.TempDir()

	recorder := filepath.Join(dir, "recorded-security")
	if err := os.WriteFile(recorder, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(dir, "security")
	if err := os.WriteFile(shim, []byte(SecurityShim(recorder, filepath.Join(dir, "fixture.keychain-db"))), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(shim, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("shim %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// Every generic-password call is redirected to the fixture keychain by the
// trailing [keychain] positional. Proven end to end on 2026-09-23: a secret
// stored through `wakil secrets set` was readable in the fixture keychain and
// absent from the login keychain.
func TestSecurityShimRedirectsGenericPasswordCalls(t *testing.T) {
	for _, subcommand := range []string{"add-generic-password", "find-generic-password", "delete-generic-password"} {
		got := runShim(t, subcommand, "-s", "wakil:org:ref", "-a", "wakil")
		lines := strings.Fields(strings.TrimSpace(got))
		last := lines[len(lines)-1]
		if !strings.HasSuffix(last, "fixture.keychain-db") {
			t.Fatalf("%s: last arg = %q, want the fixture keychain", subcommand, last)
		}
		if lines[0] != subcommand {
			t.Fatalf("%s: subcommand was not forwarded, got %q", subcommand, lines[0])
		}
	}
}

// Anything that is not a generic-password call passes through untouched: a
// keychain positional appended to, say, `list-keychains` would change its
// meaning rather than scope it.
func TestSecurityShimLeavesOtherSubcommandsAlone(t *testing.T) {
	got := strings.Fields(strings.TrimSpace(runShim(t, "list-keychains", "-d", "user")))
	if len(got) != 3 {
		t.Fatalf("got %v, want the three arguments unchanged", got)
	}
}

// The fixture environment is what the app is launched with, and the keychain
// isolation holds only if this PATH reaches the app's spawned Go children.
func TestFixtureEnvCarriesHomeTmpdirAndItsOwnBinFirst(t *testing.T) {
	fixture := Fixture{Root: "/f", Home: "/f/home", TmpDir: "/f/tmp", BinDir: "/f/bin"}
	env := map[string]string{}
	for _, assignment := range fixture.Env("/usr/bin:/bin", Seeded{}) {
		name, value, _ := strings.Cut(assignment, "=")
		env[name] = value
	}
	if env["HOME"] != "/f/home" {
		t.Fatalf("HOME = %q", env["HOME"])
	}
	if env["TMPDIR"] != "/f/tmp" {
		t.Fatalf("TMPDIR = %q", env["TMPDIR"])
	}
	if !strings.HasPrefix(env["PATH"], "/f/bin:") {
		t.Fatalf("PATH = %q, want the fixture bin first", env["PATH"])
	}
}

// EnvFromPS cannot recover a value containing a space, and that is how the
// runner verifies its own isolation — so a root with a space is refused up
// front rather than mis-parsed later.
func TestNewFixtureRefusesARootWithASpace(t *testing.T) {
	if _, err := NewFixture(filepath.Join(t.TempDir(), "with space")); err == nil {
		t.Fatal("want a refusal for a root containing a space")
	}
}

func TestNewFixtureBuildsItsDirectoriesAndShim(t *testing.T) {
	fixture, err := NewFixture(filepath.Join(t.TempDir(), "run1"))
	if err != nil {
		t.Fatalf("NewFixture: %v", err)
	}
	for _, dir := range []string{fixture.Home, fixture.TmpDir, fixture.BinDir} {
		info, err := os.Stat(dir)
		if err != nil || !info.IsDir() {
			t.Fatalf("%s is not a directory: %v", dir, err)
		}
	}
	info, err := os.Stat(filepath.Join(fixture.BinDir, "security"))
	if err != nil {
		t.Fatalf("shim missing: %v", err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatal("shim is not executable")
	}
}

// TestFixtureEnvNamesTheFixtureKeychain. The shim on PATH stopped reaching
// the product at #201, when `wakilcore` began invoking /usr/bin/security by
// absolute path. This variable is what reaches it, and it is what
// `VerifyIsolation` now requires on the app and on every Go child it
// spawned.
func TestFixtureEnvNamesTheFixtureKeychain(t *testing.T) {
	fixture := Fixture{Root: "/f", Home: "/f/home", TmpDir: "/f/tmp", BinDir: "/f/bin",
		Keychain: "/f/fixture.keychain-db"}
	env := map[string]string{}
	for _, assignment := range fixture.Env("/usr/bin:/bin", Seeded{}) {
		name, value, _ := strings.Cut(assignment, "=")
		env[name] = value
	}
	if env[KeychainSelectorEnv] != fixture.Keychain {
		t.Fatalf("%s = %q, want the fixture keychain %q — without it every Keychain call "+
			"out of the shipped binary reaches the operator's login keychain",
			KeychainSelectorEnv, env[KeychainSelectorEnv], fixture.Keychain)
	}
}

// TestTheHarnessAndTheProductSpellTheSelectorTheSameWay. The harness cannot
// import `internal/wakilcore`, so the variable's name exists twice. A
// mismatch would not fail loudly: the fixture would export a name nothing
// reads, the product would fall back to the default keychain, and the guard
// would pass because it reads the harness's own spelling on both sides.
// That is #301's failure shape exactly, so it is pinned against the source.
func TestTheHarnessAndTheProductSpellTheSelectorTheSameWay(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "..", "internal", "wakilcore", "credpresence.go"))
	if err != nil {
		t.Fatal(err)
	}
	want := `keychainSelectorEnv = "` + KeychainSelectorEnv + `"`
	if !strings.Contains(string(source), want) {
		t.Fatalf("credpresence.go does not declare %s; the harness would export a variable "+
			"the product does not read", want)
	}
}
