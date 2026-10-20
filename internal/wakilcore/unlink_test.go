package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NOTE. Every test here points `securityBinary` at a fake, so nothing
// reaches the operator's real login keychain.

func unlinkFixture(t *testing.T, orgs ...string) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", orgs[0])
	for _, org := range orgs {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	return home
}

func sharedConfigDir(t *testing.T, home, name string) string {
	t.Helper()
	dir := filepath.Join(home, name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

// TestUnlinkDeletesTheRecordTheCredentialAndTheStalePointers — the three
// things an unlink deletes, all of them the organisation's own.
func TestUnlinkDeletesTheRecordTheCredentialAndTheStalePointers(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
		ClaudePath: "/usr/local/bin/claude",
	}); err != nil {
		t.Fatal(err)
	}
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-SCRATCH"); err != nil {
		t.Fatal(err)
	}
	// Both stale-pointer sites, pointed at the binding about to go.
	if err := SaveOrg("acme", Org{DefaultProvider: "main"}); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Provider: "main"}); err != nil {
		t.Fatal(err)
	}

	outcome, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatal(err)
	}

	// 1. The record.
	if !outcome.RecordRemoved {
		t.Error("RecordRemoved = false")
	}
	if _, err := LoadProviderFor("acme", "main"); err == nil {
		t.Error("the record survived")
	}
	// 2. The Keychain item — Go's first secret delete.
	if !outcome.CredentialRemoved {
		t.Error("CredentialRemoved = false")
	}
	presence, err := SecretPresenceFor("acme", ProviderTokenRef("main"))
	if err != nil {
		t.Fatal(err)
	}
	if presence.Present {
		t.Error("the keychain item survived")
	}
	// 3. The stale pointers.
	if len(outcome.PointersCleared) != 2 {
		t.Errorf("PointersCleared = %v; want both sites", outcome.PointersCleared)
	}
	record, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if record.DefaultProvider != "" {
		t.Errorf("org.json still names the gone provider: %q", record.DefaultProvider)
	}
	active, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if active.Provider != "" {
		t.Errorf("active.json still names the gone provider: %q", active.Provider)
	}
}

// TestAfterAnUnlinkTheOrganisationFileIsWritableAgain is why clearing the
// pointers is NOT housekeeping.
//
// `SaveOrg` refuses to write a record whose `defaultProvider` names
// nothing registered. Left behind, the settings pane's own organisation
// form would refuse to save a field the operator never touched — the pane
// breaking its own form.
func TestAfterAnUnlinkTheOrganisationFileIsWritableAgain(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
	}); err != nil {
		t.Fatal(err)
	}
	if err := SaveOrg("acme", Org{DisplayName: "Acme", DefaultProvider: "main"}); err != nil {
		t.Fatal(err)
	}

	if _, err := UnlinkProvider("acme", "main"); err != nil {
		t.Fatal(err)
	}

	// The pane's own form, saving a different field entirely.
	displayName := "Acme Corporation"
	if err := UpdateOrg("acme", OrgPatch{DisplayName: &displayName}); err != nil {
		t.Fatalf("the organisation form is broken after an unlink: %v", err)
	}
}

// TestUnlinkNeverRefusesAndBackfillsBeforeItDeletes.
//
// `RemoveProvider` refuses to remove a record that HOMES a directory other
// records share. That refusal rests on a claim measured false: what it
// actually guarded is one optional field, the agent binary a sharer
// inherits. Unlink backfills it and proceeds.
func TestUnlinkNeverRefusesAndBackfillsBeforeItDeletes(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme", "personal")
	dir := sharedConfigDir(t, home, ".claude-shared")

	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
		ClaudePath: "/usr/local/bin/claude",
	}); err != nil {
		t.Fatal(err)
	}
	// A sharer with NO claudePath of its own — it inherits from the home
	// about to go, which is exactly what the old refusal protected.
	if err := AddProvider("personal", Provider{
		ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: dir, Shared: true,
	}); err != nil {
		t.Fatal(err)
	}

	// The old door still refuses, which is what makes this a change
	// rather than a no-op.
	if err := RemoveProvider("acme", "main"); err == nil {
		t.Fatal("RemoveProvider stopped refusing; this test no longer proves anything")
	}

	outcome, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatalf("unlink refused: %v", err)
	}
	if !outcome.RecordRemoved {
		t.Fatal("the record was not removed")
	}
	if len(outcome.Backfilled) != 1 || outcome.Backfilled[0] != "personal/work" {
		t.Errorf("Backfilled = %v", outcome.Backfilled)
	}

	// **The sharer still resolves**, which is the whole point of
	// backfilling before the delete.
	sharer, err := LoadProviderFor("personal", "work")
	if err != nil {
		t.Fatal(err)
	}
	if sharer.ClaudePath != "/usr/local/bin/claude" {
		t.Errorf("the sharer did not inherit the binary: %+v", sharer)
	}
	if _, err := ResolveProviderClaudePath(*sharer); err != nil {
		t.Errorf("the sharer no longer resolves: %v", err)
	}
	// And the directory has a home again: the promoted sharer.
	homeOrg, homeID, err := ConfigDirHome(dir)
	if err != nil {
		t.Fatal(err)
	}
	if homeOrg != "personal" || homeID != "work" {
		t.Errorf("home = (%q, %q); the directory was left orphaned", homeOrg, homeID)
	}
}

// TestUnlinkNeverTouchesTheConfigDirectory. The Keychain item is named
// from a hash of the directory path, so deleting the directory makes the
// item's name uncomputable.
func TestUnlinkNeverTouchesTheConfigDirectory(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	marker := filepath.Join(dir, ".claude.json")
	if err := os.WriteFile(marker, []byte(`{"signed":"in"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
	}); err != nil {
		t.Fatal(err)
	}

	outcome, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if outcome.ConfigDir != dir {
		t.Errorf("ConfigDir = %q; the outcome must name what survived", outcome.ConfigDir)
	}
	contents, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("the config dir was touched: %v", err)
	}
	if string(contents) != `{"signed":"in"}` {
		t.Errorf("the sign-in changed: %s", contents)
	}
}

// TestUnlinkAlwaysSaysWhatItCouldNotDestroy — the one permanent sentence.
// A setup-token credential is revocable by nothing Wakil can reach, so an
// unlink that removed the local item must not leave the operator believing
// the credential is gone.
func TestUnlinkAlwaysSaysWhatItCouldNotDestroy(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
	}); err != nil {
		t.Fatal(err)
	}
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-SCRATCH"); err != nil {
		t.Fatal(err)
	}

	outcome, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if !outcome.CredentialRemoved {
		t.Fatal("the local item was not removed, so this tests the wrong case")
	}
	var found bool
	for _, note := range outcome.Notes {
		if note == MintedTokenIrrevocableNote {
			found = true
		}
	}
	if !found {
		t.Errorf("the permanent sentence is missing: %v", outcome.Notes)
	}
}

// TestUnlinkingABindingWithNoCredentialStillSucceeds. Three bindings on
// this machine are in exactly this state, and unlink exists partly to
// clean them up — so "there was nothing to delete" must not be a failure.
func TestUnlinkingABindingWithNoCredentialStillSucceeds(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
	}); err != nil {
		t.Fatal(err)
	}

	outcome, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatalf("unlink refused a credential-less binding: %v", err)
	}
	if !outcome.RecordRemoved {
		t.Error("the record was not removed")
	}
	if outcome.CredentialRemoved {
		t.Error("CredentialRemoved = true with nothing to remove")
	}
}

// TestTheLastBindingIsReportedAsSuch. Revocation is refused on Invariant 4
// with the last unlink the sole exception — an OFFER, never automatic — so
// the outcome has to say which case this was.
func TestTheLastBindingIsReportedAsSuch(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme", "personal")
	dir := sharedConfigDir(t, home, ".claude-shared")
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
		ClaudePath: "/usr/local/bin/claude",
	}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("personal", Provider{
		ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: dir, Shared: true,
	}); err != nil {
		t.Fatal(err)
	}

	// Another organisation still holds the account.
	first, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if first.WasLastBinding {
		t.Error("WasLastBinding = true while another organisation still held the account")
	}

	// Now nobody does.
	second, err := UnlinkProvider("personal", "work")
	if err != nil {
		t.Fatal(err)
	}
	if !second.WasLastBinding {
		t.Error("WasLastBinding = false for the last binding to the account")
	}
}

// TestRevocationIsNeverPerformedAutomatically. Nothing in the unlink path
// shells out to a logout, and the note that offers one warns that the CLI
// reports success even when it revoked nothing.
func TestRevocationIsNeverPerformedAutomatically(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	marker := filepath.Join(dir, ".claude.json")
	if err := os.WriteFile(marker, []byte(`{"signed":"in"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
	}); err != nil {
		t.Fatal(err)
	}

	outcome, err := UnlinkProvider("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if !outcome.WasLastBinding {
		t.Fatal("the fixture is not the last-binding case")
	}
	// The sign-in is untouched: nothing logged anything out.
	if _, err := os.ReadFile(marker); err != nil {
		t.Errorf("the sign-in was revoked automatically: %v", err)
	}
	// And the warning names the CLI's own dishonesty.
	if !strings.Contains(RevocationUnreliableNote, "reports") ||
		!strings.Contains(RevocationUnreliableNote, "revoked nothing") {
		t.Errorf("the revocation warning does not say the CLI lies: %q", RevocationUnreliableNote)
	}
}

// TestUnlinkOnlyClearsTheCurrentOrganisationsActiveContext. Another
// organisation's active context is inside a boundary this call is not.
func TestUnlinkOnlyClearsTheCurrentOrganisationsActiveContext(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme", "personal")
	dir := sharedConfigDir(t, home, ".claude-other")
	if err := AddProvider("personal", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir,
	}); err != nil {
		t.Fatal(err)
	}
	// WAKIL_ORG is "acme"; the active context belongs to it and names a
	// provider that happens to share the id being unlinked elsewhere.
	if err := WriteActive(ActiveContext{Provider: "main"}); err != nil {
		t.Fatal(err)
	}

	if _, err := UnlinkProvider("personal", "main"); err != nil {
		t.Fatal(err)
	}
	active, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if active.Provider != "main" {
		t.Errorf("unlinking in another organisation cleared this one's active context")
	}
}

// TestSecretDeleteTreatsAnAbsentItemAsSuccess, so unlink never refuses.
func TestSecretDeleteTreatsAnAbsentItemAsSuccess(t *testing.T) {
	useFakeSecurity(t, `exit 44`)
	if err := SecretDelete("acme", "provider:main"); err != nil {
		t.Fatalf("deleting an absent item was an error: %v", err)
	}
}

// TestSecretDeleteReportsARealFailure. A locked keychain is not "there was
// nothing there", and the surface has to be able to say which.
func TestSecretDeleteReportsARealFailure(t *testing.T) {
	useFakeSecurity(t, `echo "User interaction is not allowed." >&2; exit 51`)
	err := SecretDelete("acme", "provider:main")
	if err == nil {
		t.Fatal("a keychain failure was reported as success")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v", err)
	}
	if !strings.Contains(msg, "User interaction is not allowed") {
		t.Errorf("the diagnostic was dropped: %q", msg)
	}
}

// A pinned process unlinking the active provider must clear only the
// provider; the pinned project and environment must not reach active.json.
func TestUnlinkInAPinnedProcessDoesNotPersistThePins(t *testing.T) {
	fakeKeychain(t)
	home := unlinkFixture(t, "acme")
	dir := sharedConfigDir(t, home, ".claude-main")
	if err := AddProvider("acme", Provider{ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: dir, ClaudePath: "/usr/local/bin/claude"}); err != nil {
		t.Fatal(err)
	}
	pp := filepath.Join(home, "p", ".wakil", "project.json")
	if err := os.MkdirAll(filepath.Dir(pp), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pp, []byte(`{"name":"p","org":"acme","roots":[{"path":"."}],"environments":{}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("acme", map[string]ProjectEntry{"p": {Path: pp}}); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: "/operator/own", Environment: "staging", Provider: "main"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROJECT", "p")
	t.Setenv("WAKIL_ENVIRONMENT", "local")
	if _, err := UnlinkProvider("acme", "main"); err != nil {
		t.Fatal(err)
	}
	got, err := ReadActiveUnpinned()
	if err != nil {
		t.Fatal(err)
	}
	want := ActiveContext{Project: "/operator/own", Environment: "staging"}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestUnlinkClearsQuickProvider(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	id := "qwen"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &id}); err != nil {
		t.Fatal(err)
	}
	if _, err := UnlinkProvider("initech", "qwen"); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if o.QuickProvider != "" {
		t.Errorf("org.json still names the gone provider: %q", o.QuickProvider)
	}
}
