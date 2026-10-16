package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NOTE ON KEYCHAIN SAFETY. Every test here overrides `securityBinary` to
// point at a fake script, so nothing reaches the operator's real login
// keychain. See the note at the head of secrets_test.go.

// fakeKeychain stands in for `security` with a store kept on disk:
// `add-generic-password -w V` writes V to a file named after the service,
// `find-generic-password -w` reads it back, the same lookup without `-w`
// reports attributes only, and `delete-generic-password` removes it.
//
// That is enough to exercise the three operations this phase adds: #201's
// COPY (a read from one org's item followed by a write to another's),
// #200's PRESENCE check (which must ask for no value), and #206's DELETE.
// Exit 44 stands for "no such item" throughout, as the real tool does.
func fakeKeychain(t *testing.T) {
	t.Helper()
	store := t.TempDir()
	script := `
store=` + store + `
cmd="$1"; shift
service=""; value=""; want_value=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) service="$2"; shift 2 ;;
    -w)
      if [ "$cmd" = "add-generic-password" ]; then
        value="$2"; shift 2
      else
        want_value=1; shift
      fi
      ;;
    *) shift ;;
  esac
done
file="$store/$(printf '%s' "$service" | tr '/:' '__')"
case "$cmd" in
  add-generic-password) printf '%s' "$value" > "$file"; exit 0 ;;
  delete-generic-password)
    [ -f "$file" ] || exit 44
    rm -f "$file"
    exit 0 ;;
  find-generic-password)
    [ -f "$file" ] || exit 44
    if [ "$want_value" = "1" ]; then cat "$file"; echo; else
      echo 'attributes:'
      echo '    "mdat"<timedate>=0xAA  "20260922130257Z\000"'
    fi
    exit 0 ;;
esac
exit 1
`
	path := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	previous := securityBinary
	securityBinary = keychainTool(path)
	t.Cleanup(func() { securityBinary = previous })
}

func adoptFixture(t *testing.T) (home, configDir string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"initech", "personal"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	configDir = filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: resolved,
		ClaudePath: "/usr/local/bin/claude",
	}); err != nil {
		t.Fatal(err)
	}
	return home, resolved
}

// TestAdoptCopiesTheCredentialItHasNeverCopied is the defect this ticket
// pays, stated as the scenario that produces it: a shared account means
// the same token stored twice, once per organisation, because
// ProviderTokenRef carries no org. Forget the second copy and the window
// refuses to start against a Keychain item that simply does not exist —
// which is the state three bindings on this machine are in today.
func TestAdoptCopiesTheCredentialItHasNeverCopied(t *testing.T) {
	fakeKeychain(t)
	_, configDir := adoptFixture(t)
	if err := SecretSetFor("initech", ProviderTokenRef("main"), "sk-ant-oat01-source"); err != nil {
		t.Fatal(err)
	}

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "personal", ID: "work", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, FromOrg: "initech", FromID: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !outcome.CredentialCopied {
		t.Fatalf("the credential was not copied: %q", outcome.CredentialNote)
	}

	// The adopting organisation's OWN item now holds it, under the
	// adopting organisation's OWN id — the two ids are independent
	// because the operator may choose their own.
	got, err := SecretGetFor("personal", ProviderTokenRef("work"))
	if err != nil {
		t.Fatal(err)
	}
	if got != "sk-ant-oat01-source" {
		t.Errorf("copied credential = %q", got)
	}
	// And the source is untouched — a copy, never a move.
	source, err := SecretGetFor("initech", ProviderTokenRef("main"))
	if err != nil || source != "sk-ant-oat01-source" {
		t.Errorf("the source credential changed: %q, %v", source, err)
	}
}

// TestAdoptRecordsTheResolvedAgentBinary. The argument did not exist at
// all before this ticket, so this ADDS one rather than populating it — and
// it is resolved from the source rather than guessed, which is what makes
// a shared binding inherit a real binary even when its own record names
// none.
func TestAdoptRecordsTheResolvedAgentBinary(t *testing.T) {
	fakeKeychain(t)
	_, configDir := adoptFixture(t)

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "personal", ID: "work", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, FromOrg: "initech", FromID: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	if outcome.ClaudePath != "/usr/local/bin/claude" {
		t.Fatalf("ClaudePath = %q", outcome.ClaudePath)
	}
	adopted, err := LoadProviderFor("personal", "work")
	if err != nil {
		t.Fatal(err)
	}
	if adopted.ClaudePath != "/usr/local/bin/claude" {
		t.Errorf("the record does not carry the resolved binary: %+v", adopted)
	}
	// It is a share: the home does not move.
	if !adopted.Shared {
		t.Error("an adoption did not record itself as shared")
	}
	org, id, err := ConfigDirHome(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if org != "initech" || id != "main" {
		t.Errorf("adoption moved the home to (%q, %q)", org, id)
	}
}

// TestAdoptingADirectoryNothingHomesBecomesTheHome — the second of the two
// add-path changes, reached through the door the settings pane actually
// uses. The pane's Adopt control has no `--share` to drop, so this path
// has to handle an orphaned directory rather than refuse it.
func TestAdoptingADirectoryNothingHomesBecomesTheHome(t *testing.T) {
	fakeKeychain(t)
	home, configDir := adoptFixture(t)
	_ = home

	// The home record, removed by hand — how this state is reached.
	providers, err := providersDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(providers, "main.json")); err != nil {
		t.Fatal(err)
	}

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "personal", ID: "work", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, FromOrg: "initech", FromID: "main",
	})
	if err != nil {
		t.Fatalf("adopting an orphaned directory was refused: %v", err)
	}
	if !outcome.BecameHome {
		t.Error("BecameHome = false for a directory nothing homed")
	}
	org, id, err := ConfigDirHome(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if org != "personal" || id != "work" {
		t.Errorf("home = (%q, %q)", org, id)
	}
}

// TestAdoptSurvivesASourceWithNoCredential. A source that holds nothing
// does not fail the adoption: the binding is real, the row draws, and it
// reports its credential missing — which is true and repairable from that
// row. Failing would leave the operator with neither a binding nor an
// explanation.
func TestAdoptSurvivesASourceWithNoCredential(t *testing.T) {
	fakeKeychain(t)
	_, configDir := adoptFixture(t)

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "personal", ID: "work", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, FromOrg: "initech", FromID: "main",
	})
	if err != nil {
		t.Fatalf("adoption failed because the source had no credential: %v", err)
	}
	if outcome.CredentialCopied {
		t.Error("CredentialCopied = true with nothing to copy")
	}
	if outcome.CredentialNote == "" {
		t.Error("nothing was copied and nothing said so")
	}
	if !strings.Contains(outcome.CredentialNote, "cannot start a session") &&
		!strings.Contains(outcome.CredentialNote, "holds no credential") {
		t.Errorf("the note does not say what it costs: %q", outcome.CredentialNote)
	}
	// The binding exists regardless.
	if _, err := LoadProviderFor("personal", "work"); err != nil {
		t.Errorf("the binding was not written: %v", err)
	}
}

// TestAdoptWithNoSourceCopiesNothingAndSaysNothing. A caller with no
// source is not an error and not a warning — it is a plain registration,
// and a note there would be a complaint about something nobody asked for.
func TestAdoptWithNoSourceCopiesNothingAndSaysNothing(t *testing.T) {
	fakeKeychain(t)
	_, configDir := adoptFixture(t)

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "personal", ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: configDir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if outcome.CredentialCopied || outcome.CredentialNote != "" {
		t.Errorf("outcome = %+v", outcome)
	}
}

// TestAdoptDoesNotCopyAnItemOntoItself. Adopting within one organisation
// under the same id would read and write the same Keychain item; under a
// different id it is meaningless, because the source binding's credential
// already serves that organisation.
func TestAdoptDoesNotCopyAnItemOntoItself(t *testing.T) {
	fakeKeychain(t)
	_, configDir := adoptFixture(t)
	if err := SecretSetFor("initech", ProviderTokenRef("main"), "sk-ant-oat01-source"); err != nil {
		t.Fatal(err)
	}

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "initech", ID: "main", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, FromOrg: "initech", FromID: "main",
	})
	// The add itself is refused — one org may name one account once — and
	// that refusal is the answer here.
	if err == nil {
		t.Fatal("one org registered the same account twice")
	}
	if outcome.CredentialCopied {
		t.Error("a credential was copied by a refused adoption")
	}
}

// TestAdoptNamesAKeychainFailureRatherThanSwallowingIt. A locked keychain
// or a denied prompt is not "the source holds nothing", and the operator
// has to be told which — one is repaired by signing in, the other by
// unlocking.
func TestAdoptNamesAKeychainFailureRatherThanSwallowingIt(t *testing.T) {
	_, configDir := adoptFixture(t)
	// Set AFTER the fixture, so the fixture's own writes succeed and only
	// the copy meets the broken tool.
	path := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(path, []byte("#!/bin/sh\necho 'User interaction is not allowed.' >&2\nexit 51\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	previous := securityBinary
	securityBinary = keychainTool(path)
	t.Cleanup(func() { securityBinary = previous })

	outcome, err := AdoptProvider(AdoptRequest{
		Org: "personal", ID: "work", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, FromOrg: "initech", FromID: "main",
	})
	if err != nil {
		t.Fatalf("a keychain failure undid the adoption: %v", err)
	}
	if outcome.CredentialCopied {
		t.Error("CredentialCopied = true after a keychain failure")
	}
	if !strings.Contains(outcome.CredentialNote, "User interaction is not allowed") {
		t.Errorf("the diagnostic was dropped: %q", outcome.CredentialNote)
	}
}
