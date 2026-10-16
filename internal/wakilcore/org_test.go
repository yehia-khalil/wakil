package wakilcore

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestCreateOrgRefusesBadJiraBase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, bad := range []string{
		"http://site.atlassian.net",
		"https://u:p@site.atlassian.net",
		"https://site.atlassian.net/wiki",
		"https://site.atlassian.net?q=1",
	} {
		t.Run(bad, func(t *testing.T) {
			if err := CreateOrg("initech", Org{JiraBase: bad}); err == nil {
				t.Fatalf("CreateOrg accepted %q", bad)
			}
			if _, err := OrgDirFor("initech"); err == nil {
				t.Errorf("a rejected org must not be left half-created on disk")
			}
		})
	}
}

func TestCreateOrgNormalisesJiraBaseAndRoundTrips(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{DisplayName: "Initech Labs", JiraBase: "https://site.atlassian.net/"}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrg()
	if err != nil {
		t.Fatal(err)
	}
	if o.JiraBase != "https://site.atlassian.net" {
		t.Errorf("JiraBase = %q; want the trailing slash normalised away", o.JiraBase)
	}
	if o.DisplayName != "Initech Labs" {
		t.Errorf("DisplayName = %q", o.DisplayName)
	}
}

func TestCreateOrgRefusesDuplicate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := CreateOrg("initech", Org{}); err == nil {
		t.Fatal("CreateOrg overwrote an existing org")
	}
}

// TestCreateOrgRefusesUnregisteredDefaultProvider pins finding 2 of the
// final review: spec §4.1 requires DefaultProvider, when set, to name a
// REGISTERED provider — the same rule LoadProviderFor already enforces
// on every other caller of a provider id. Before this guard,
// normaliseOrg checked only the token's SHAPE, so a typo'd
// --default-provider silently landed in org.json and surfaced only much
// later as a provider mismatch nobody could act on.
//
// The org's directory can never actually hold a matching provider here —
// CreateOrg makes the directory itself, so nothing could have been
// registered under it beforehand — which is exactly the ordering
// consequence finding 2 calls out: `org create --default-provider X`
// can no longer succeed, full stop, mirroring the refusal `provider add`
// already imposes on every other unregistered id.
func TestCreateOrgRefusesUnregisteredDefaultProvider(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	err := CreateOrg("initech", Org{DefaultProvider: "nosuch"})
	if err == nil {
		t.Fatal("CreateOrg accepted a defaultProvider naming no registered provider")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected a UserError, got %T: %v", err, err)
	}
	if !strings.Contains(err.Error(), "register it with") {
		t.Errorf("error = %q, want LoadProviderFor's own registration hint", err.Error())
	}
	if _, err := OrgDirFor("initech"); err == nil {
		t.Error("a rejected org must not be left half-created on disk")
	}
}

// TestSaveOrgRefusesUnregisteredDefaultProvider is TestCreateOrgRefusesUnregisteredDefaultProvider's
// SaveOrg counterpart: an org that already exists must not be able to
// adopt a defaultProvider that names no provider registered under it
// either.
func TestSaveOrgRefusesUnregisteredDefaultProvider(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	err := SaveOrg("initech", Org{DefaultProvider: "nosuch"})
	if err == nil {
		t.Fatal("SaveOrg accepted a defaultProvider naming no registered provider")
	}
	if !strings.Contains(err.Error(), "register it with") {
		t.Errorf("error = %q, want LoadProviderFor's own registration hint", err.Error())
	}
}

// TestSaveOrgAcceptsARegisteredDefaultProvider is the positive case: once
// a provider is actually registered under the org, naming it as
// defaultProvider must succeed.
func TestSaveOrgAcceptsARegisteredDefaultProvider(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "primary", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	if err := SaveOrg("initech", Org{DefaultProvider: "primary"}); err != nil {
		t.Fatalf("SaveOrg rejected a defaultProvider that IS registered: %v", err)
	}
	o, err := LoadOrgFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if o.DefaultProvider != "primary" {
		t.Errorf("DefaultProvider = %q, want %q to round-trip", o.DefaultProvider, "primary")
	}
}

// TestSaveOrgDefaultProviderBadShapeNamesTheProviderNotTheOrg pins finding
// 3 of the final review: a malformed defaultProvider used to be checked
// with validateOrgToken, whose message calls the value an "org id" — so
// `wakil org set initech --default-provider "bad!"` read as "defaultProvider
// is not a usable provider id: unusable ORG id \"bad!\"", contradicting
// itself in one sentence. validateProviderToken exists precisely so a
// rejected provider id reads as a provider id.
func TestSaveOrgDefaultProviderBadShapeNamesTheProviderNotTheOrg(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	err := SaveOrg("initech", Org{DefaultProvider: "bad provider id"})
	if err == nil {
		t.Fatal("SaveOrg accepted a defaultProvider with illegal characters")
	}
	msg := err.Error()
	if strings.Contains(msg, "org id") {
		t.Errorf("error = %q, must not call a bad provider id an \"org id\"", msg)
	}
	if !strings.Contains(msg, "provider id") {
		t.Errorf("error = %q, want it to name a provider id", msg)
	}
}

// TestRemoveOrgProviderCountIgnoresNonProviderEntries pins finding 11 of
// the final review: RemoveOrg's dependant count used to be a bare
// len(os.ReadDir(...)) over providers/, so a stray subdirectory or a
// non-.json file inflated the count past what `wakil provider list`
// would ever show. It must apply the exact filter listProvidersFor uses
// (provider.go): skip directories, skip anything not named "*.json".
//
// An org whose ONLY providers/ entries are a subdirectory and a dotfile
// must therefore be removable WITHOUT --force.
func TestRemoveOrgProviderCountIgnoresNonProviderEntries(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, ".wakil", "orgs", "initech", "providers")
	if err := os.MkdirAll(filepath.Join(dir, "a-stray-subdir"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".DS_Store"), []byte("not a provider"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RemoveOrg("initech", false); err != nil {
		t.Fatalf("RemoveOrg(false) = %v; a stray subdirectory and a non-.json file are not provider records", err)
	}
}

func TestRemoveOrgRefusesWhenItHasDependants(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, ".wakil", "orgs", "initech", "providers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "primary.json"), []byte(`{"kind":"local"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RemoveOrg("initech", false); err == nil {
		t.Fatal("RemoveOrg deleted an org that still held a provider")
	}
	if err := RemoveOrg("initech", true); err != nil {
		t.Fatalf("forced RemoveOrg failed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "orgs", "initech")); !os.IsNotExist(err) {
		t.Error("forced RemoveOrg must delete the whole org directory")
	}
}

func TestListOrgsIsSortedAndNeverNil(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, o := range []string{"umbrella", "initech", "personal"} {
		if err := CreateOrg(o, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	got, err := ListOrgs()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"initech", "personal", "umbrella"}
	if !slices.Equal(got, want) {
		t.Errorf("ListOrgs() = %v; want %v", got, want)
	}
}
