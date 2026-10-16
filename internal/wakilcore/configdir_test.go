package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDeriveConfigDirIsAPureFunctionOfTheId. The operator never types or
// sees a path, and re-entry costs one trip rather than two precisely
// because the next add of the same id computes the same directory (#205).
func TestDeriveConfigDirIsAPureFunctionOfTheId(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resolvedHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}

	first, err := DeriveConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	second, err := DeriveConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("two derivations disagreed: %q and %q", first, second)
	}
	if want := filepath.Join(resolvedHome, ".claude-acme"); first != want {
		t.Fatalf("DeriveConfigDir = %q; want %q", first, want)
	}
	// Different ids, different directories — one directory per account.
	other, err := DeriveConfigDir("other")
	if err != nil {
		t.Fatal(err)
	}
	if other == first {
		t.Error("two ids derived the same directory")
	}
}

// TestDeriveConfigDirResolvesASymlinkedHome is the one-string rule at the
// point where it can break.
//
// The CLI hashes the LITERAL string it is handed to name the Keychain
// item, and does not resolve symlinks. So a spawn handed the unresolved
// derivation, plus an AddProvider storing the resolved one, gives Go a
// Keychain name the login never wrote to — a fresh, correct sign-in that
// reads as logged out. Resolving ONCE, here, is what makes the spawn, the
// record and the hash agree.
//
// MUTATION CHECK: dropping the EvalSymlinks call makes this fail.
func TestDeriveConfigDirResolvesASymlinkedHome(t *testing.T) {
	real := t.TempDir()
	resolvedReal, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "home-link")
	if err := os.Symlink(resolvedReal, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	t.Setenv("HOME", link)
	got, err := DeriveConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasPrefix(got, link) {
		t.Fatalf("DeriveConfigDir = %q; the symlinked home was not resolved", got)
	}
	if want := filepath.Join(resolvedReal, ".claude-acme"); got != want {
		t.Fatalf("DeriveConfigDir = %q; want %q", got, want)
	}
}

// TestDeriveConfigDirAnswersBeforeTheDirectoryExists. The whole point is
// to name a directory that usually does not exist yet — the pane spawns a
// login before any record exists — and `filepath.EvalSymlinks` fails on a
// path that is not there, which is why the PARENT is resolved rather than
// the directory itself.
func TestDeriveConfigDirAnswersBeforeTheDirectoryExists(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	dir, err := DeriveConfigDir("brand-new")
	if err != nil {
		t.Fatalf("derivation failed for a directory that does not exist: %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("the fixture's directory already exists: %v", err)
	}
	if dir == "" {
		t.Fatal("derivation answered an empty path")
	}
}

// TestEnsureConfigDirReturnsTheSameStringItDerived. Creating a directory
// must not change the string that names it, or the one-string rule is
// broken by the very call that prepares the ground for it.
func TestEnsureConfigDirReturnsTheSameStringItDerived(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	derived, err := DeriveConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	created, err := EnsureConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	if created != derived {
		t.Fatalf("EnsureConfigDir = %q; DeriveConfigDir = %q", created, derived)
	}
	info, err := os.Stat(created)
	if err != nil || !info.IsDir() {
		t.Fatalf("the directory was not created: %v", err)
	}

	// And again, now that it exists: still the same string.
	again, err := EnsureConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	if again != derived {
		t.Fatalf("a second EnsureConfigDir = %q; want %q", again, derived)
	}
}

// TestDeriveConfigDirRefusesAnIdItCannotName. A provider id is already
// constrained to the character set a Keychain ref and a filename both
// need; an id carrying a slash would derive a path outside the home
// directory entirely.
func TestDeriveConfigDirRefusesAnIdItCannotName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, bad := range []string{"", "../escape", "has/slash", "has space", "has:colon"} {
		t.Run(bad, func(t *testing.T) {
			if got, err := DeriveConfigDir(bad); err == nil {
				t.Fatalf("DeriveConfigDir(%q) = %q; want a refusal", bad, got)
			}
		})
	}
}

// TestEnsureConfigDirCreatesItPrivate. It holds a sign-in; the default
// umask is not the right answer for a directory whose whole contents are
// one account's credentials.
func TestEnsureConfigDirCreatesItPrivate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	dir, err := EnsureConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode&0o077 != 0 {
		t.Errorf("config dir mode = %o; want no group or other access", mode)
	}
}

// TestNothingInThisPhaseDeletesAConfigDir is #205's standing rule, pinned
// against the behaviour rather than against a grep.
//
// **Why the directory is never deleted, on any path.** The scoped Keychain
// item is named from a hash of the directory path, so deleting the
// directory makes the item's name UNCOMPUTABLE —
// `Claude Code-credentials-832632cb` on this machine is what that looks
// like afterwards: brute-forced against ~60 candidate paths and never
// identified.
//
// Leaving it is also the only disposition that behaves identically on
// cancel, on quit and on crash: the app explicitly refuses to unwind
// half-built work and has no crash hook. And it is what makes re-entry
// cost ONE trip — the sign-in is still in there.
func TestNothingInThisPhaseDeletesAConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}

	configDir, err := EnsureConfigDir("acme-main")
	if err != nil {
		t.Fatal(err)
	}
	// A marker, so "the directory is still there" means "its contents
	// survived" rather than "something re-created an empty one".
	marker := filepath.Join(configDir, ".claude.json")
	if err := os.WriteFile(marker, []byte(`{"signed":"in"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: configDir,
	}); err != nil {
		t.Fatal(err)
	}

	// The remove path — the one place in the product that deletes
	// anything provider-shaped. It removes the RECORD, never the
	// directory.
	if err := RemoveProvider("acme", "main"); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadProviderFor("acme", "main"); err == nil {
		t.Fatal("the record survived RemoveProvider, so this test proves nothing")
	}

	if _, err := os.Stat(configDir); err != nil {
		t.Fatalf("the config dir was deleted: %v", err)
	}
	contents, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("the config dir's contents were deleted: %v", err)
	}
	if string(contents) != `{"signed":"in"}` {
		t.Errorf("the sign-in was modified: %s", contents)
	}

	// And the derivation still answers the same string, which is what
	// makes re-entry cost one trip rather than two.
	again, err := DeriveConfigDir("acme-main")
	if err != nil {
		t.Fatal(err)
	}
	if again != configDir {
		t.Errorf("re-derivation = %q; want %q", again, configDir)
	}
}

// TestDeriveConfigDirResolvesASymlinkedLEAF is the review finding, and it
// is the one-string rule's actual failure mode rather than its documented
// one.
//
// `AddProvider` stores `EvalSymlinks(abs)` — the WHOLE path. A derivation
// that resolved only `$HOME` handed the spawn `<home>/.claude-<id>` while
// the record kept the link's target, so the login wrote one Keychain name
// and Go looked up another: a fresh, correct sign-in that reads as logged
// out. Reproduced on this machine, 2026-09-22, before the fix:
//
//	derived (what the spawn gets):     …/leafprobe…/.claude-acme
//	stored  (what AddProvider keeps):  …/realdir…
//
// MUTATION CHECK: resolving only the parent makes this fail.
func TestDeriveConfigDirResolvesASymlinkedLEAF(t *testing.T) {
	home := t.TempDir()
	elsewhere := t.TempDir()
	t.Setenv("HOME", home)

	resolvedHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	resolvedElsewhere, err := filepath.EvalSymlinks(elsewhere)
	if err != nil {
		t.Fatal(err)
	}
	// ~/.claude-acme is itself a symlink to somewhere else entirely.
	if err := os.Symlink(resolvedElsewhere, filepath.Join(resolvedHome, ".claude-acme")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	derived, err := DeriveConfigDir("acme")
	if err != nil {
		t.Fatal(err)
	}
	if derived != resolvedElsewhere {
		t.Fatalf("DeriveConfigDir = %q; want the link's target %q", derived, resolvedElsewhere)
	}

	// And the derivation agrees with what AddProvider stores, which is
	// the property the whole rule is about.
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("acme", Provider{
		ID: "acme", Kind: ProviderKindClaudeCode, ConfigDir: derived,
	}); err != nil {
		t.Fatal(err)
	}
	record, err := LoadProviderFor("acme", "acme")
	if err != nil {
		t.Fatal(err)
	}
	if record.ConfigDir != derived {
		t.Errorf("the record stores %q while the spawn was handed %q — one string, two values",
			record.ConfigDir, derived)
	}
}
