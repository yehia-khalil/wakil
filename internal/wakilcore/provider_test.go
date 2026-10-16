package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestAddProviderRequiresExistingConfigDirForClaudeCode(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	err := AddProvider("initech", Provider{ID: "primary", Kind: ProviderKindClaudeCode, ConfigDir: filepath.Join(home, "nope")})
	if err == nil {
		t.Fatal("AddProvider accepted a claude-code provider whose configDir does not exist")
	}
	if !strings.Contains(err.Error(), "configDir") {
		t.Errorf("the refusal must name the field; got %q", err)
	}
}

func TestAddProviderRejectsUnknownKind(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "x", Kind: "gemini"}); err == nil {
		t.Fatal("AddProvider accepted an unknown kind")
	}
}

func TestProvidersRoundTripAndSort(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "primary", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Label: "main"}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "backup", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	got, err := ListProviders()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != "backup" || got[1].ID != "primary" {
		t.Fatalf("ListProviders() = %+v; want backup then primary", got)
	}
	// AddProvider stores the symlink-RESOLVED path, and on macOS t.TempDir()
	// sits under /var, which is a symlink to /private/var. Comparing against
	// the unresolved cfg would fail there for the right reason.
	wantCfg, err := filepath.EvalSymlinks(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got[1].ConfigDir != wantCfg || got[1].Label != "main" {
		t.Errorf("provider record did not round-trip: %+v (want configDir %q)", got[1], wantCfg)
	}
}

func TestCurrentProviderRejectsUnregisteredID(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_PROVIDER", "typo")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if got, err := CurrentProvider(); err == nil {
		t.Fatalf("CurrentProvider() = %q, nil; want a refusal for an unregistered id", got)
	}
}

func TestCurrentProviderIsOptional(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_PROVIDER", "")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	got, err := CurrentProvider()
	if err != nil {
		t.Fatalf("CurrentProvider() error = %v; unset WAKIL_PROVIDER is legitimate — the operator runs the CLI by hand", err)
	}
	if got != "" {
		t.Errorf("CurrentProvider() = %q; want empty", got)
	}
}

func TestLoadProviderForRejectsTraversalID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	// providersDirFor("initech") is <OrgsDir>/initech/providers, so an id of
	// "../../secret" is exactly the traversal that would resolve to
	// <OrgsDir>/secret.json if LoadProviderFor built the path without
	// validating id first.
	orgsDir, err := OrgsDir()
	if err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(orgsDir, "secret.json")
	if err := os.WriteFile(secret, []byte(`{"kind":"local"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadProviderFor("initech", "../../secret"); err == nil {
		t.Fatal("LoadProviderFor accepted a traversal-shaped id")
	}
}

func TestRemoveProviderRejectsTraversalID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	orgsDir, err := OrgsDir()
	if err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(orgsDir, "victim.json")
	if err := os.WriteFile(victim, []byte(`{"kind":"local"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RemoveProvider("initech", "../../victim"); err == nil {
		t.Fatal("RemoveProvider accepted a traversal-shaped id")
	}
	if _, err := os.Stat(victim); err != nil {
		t.Fatalf("victim file outside providers/ was removed: %v", err)
	}
}

func TestListProvidersForReportsSkippedCorruptRecords(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "good", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	dir, err := providersDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "corrupt.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	providers, skipped, err := listProvidersFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if len(providers) != 1 || providers[0].ID != "good" {
		t.Fatalf("listProvidersFor providers = %+v; want just %q", providers, "good")
	}
	if len(skipped) != 1 || skipped[0] != "corrupt" {
		t.Fatalf("listProvidersFor skipped = %v; want [\"corrupt\"]", skipped)
	}
}

// The tests below cover the config-dir collision guard. Its reason for
// existing is not local to this package: scripts/register-provider.sh
// writes the five MCP servers into a provider's configDir under fixed
// names, each pinned with -e WAKIL_ORG and -e WAKIL_PROVIDER, so a config
// dir carries exactly one PINNED (org, provider) pair and a second
// registration silently overwrites the first. The first symptom is a
// session running as the wrong org — the very failure those -e flags exist
// to prevent. See "One config dir serves one org" in
// docs/wakil/phase-1-acceptance.md.
//
// What sharing changed, since the paragraph above was written before it:
// the pin is still one org's, and register-provider.sh is still the only
// thing that writes it — but the RECORDS naming a dir are no longer
// one-to-one with it. Other orgs may hold Wakil-only bindings behind
// --share, which never register anything and never touch the pin. So the
// rule these tests guard is narrower than it used to be and is stated in
// two halves: one org may name one config dir ONCE, and one config dir has
// at most one HOME.

// addClaudeProvider registers a claude-code provider against a config dir
// it creates, returning that dir resolved (filepath.EvalSymlinks), the same
// form AddProvider itself persists — so a caller can compare the return
// value against another resolved path (e.g. ConfigDirHome's output)
// without the two disagreeing over an unresolved symlink component (on
// macOS, t.TempDir() vs. its /private/var-prefixed resolved form). The
// three-line mkdir/AddProvider dance is the setup for every collision test
// below and nothing else.
func addClaudeProvider(t *testing.T, home, org, id, dirName string) string {
	t.Helper()
	cfg := filepath.Join(home, dirName)
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider(org, Provider{ID: id, Kind: ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatal(err)
	}
	// Resolved, not the raw path built above: AddProvider stores the
	// EvalSymlinks'd value (provider.go's "resolve symlinks" step), and on
	// macOS a t.TempDir() path differs from its resolved form (/var is a
	// symlink to /private/var). A caller that compares this return value
	// against ConfigDirHome's output needs the same string AddProvider
	// actually persisted, or the two never match.
	resolved, err := filepath.EvalSymlinks(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

// writeProviderRecord writes a provider record straight to disk, bypassing
// AddProvider. Needed because some fixtures are states AddProvider will
// not create for you — a shared record before AddProvider learns --share,
// for instance.
func writeProviderRecord(t *testing.T, home, org, id string, p Provider) {
	t.Helper()
	dir := filepath.Join(home, ".wakil/orgs", org, "providers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, id+".json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestAddProviderRejectsConfigDirClaimedByAnotherOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"initech", "personal"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

	err := AddProvider("personal", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg})
	if err == nil {
		t.Fatal("AddProvider accepted a configDir already registered under another org")
	}
	// The operator's next question is always "registered to what?", so the
	// refusal has to answer it without a second command.
	for _, want := range []string{`"initech"`, `"main"`} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal must name the owning org and provider; %s missing from %q", want, err)
		}
	}
	// A refused add must leave nothing behind.
	if _, err := LoadProviderFor("personal", "work"); err == nil {
		t.Error("a refused AddProvider still wrote a provider record")
	}
}

func TestAddProviderRejectsConfigDirClaimedWithinSameOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

	// Same org, different id: WAKIL_ORG would survive, but WAKIL_PROVIDER
	// would not, so sessions land under the wrong provider. Same bug, one
	// level down.
	if err := AddProvider("initech", Provider{ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: cfg}); err == nil {
		t.Fatal("AddProvider accepted a configDir already registered to another provider in the same org")
	}
}

func TestAddProviderRejectsSymlinkToClaimedConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"initech", "personal"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

	// A symlink is the same directory by another name. Comparing the two
	// paths as strings would miss this and let the collision through.
	link := filepath.Join(home, "claude-link")
	if err := os.Symlink(cfg, link); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("personal", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: link}); err == nil {
		t.Fatal("AddProvider accepted a symlink to a configDir already registered under another org")
	}
}

func TestAddProviderReportsDuplicateIDRatherThanCollision(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

	// Re-adding the same id against its own configDir is a duplicate id, and
	// saying so is more useful than reporting a collision with itself.
	err := AddProvider("initech", Provider{ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: cfg})
	if err == nil {
		t.Fatal("AddProvider accepted a duplicate id")
	}
	if !strings.Contains(err.Error(), "already exists") {
		t.Errorf("re-adding an id must report the duplicate id, not a configDir collision; got %q", err)
	}
}

func TestAddProviderAllowsConfigDirFreedByRemove(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"initech", "personal"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

	// `provider rm` then `provider add` is the whole escape hatch — there is
	// deliberately no --force — so it has to actually work.
	if err := RemoveProvider("initech", "main"); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("personal", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatalf("AddProvider refused a configDir released by RemoveProvider: %v", err)
	}
}

func TestAddProviderCollisionGuardIgnoresKindsWithoutConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"initech", "personal"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	if err := AddProvider("initech", Provider{ID: "local1", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	// Two providers with no configDir at all share the empty string. Matching
	// on it would make the second registration collide with the first.
	if err := AddProvider("personal", Provider{ID: "local2", Kind: ProviderKindLocal}); err != nil {
		t.Fatalf("AddProvider refused a second provider that has no configDir: %v", err)
	}
}

func TestProviderClaudePathRoundTrips(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	configDir := t.TempDir()
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, ClaudePath: "/opt/bin/claude",
	}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}
	got, err := LoadProviderFor("acme", "main")
	if err != nil {
		t.Fatalf("LoadProviderFor: %v", err)
	}
	if got.ClaudePath != "/opt/bin/claude" {
		t.Fatalf("ClaudePath = %q, want /opt/bin/claude", got.ClaudePath)
	}
}

func TestProviderTokenRefIsDerivedFromID(t *testing.T) {
	if got := ProviderTokenRef("main"); got != "provider:main" {
		t.Fatalf("ProviderTokenRef = %q, want provider:main", got)
	}
}

func TestProviderSharedRoundTripsAndIsOmittedWhenFalse(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: cfg,
	}); err != nil {
		t.Fatal(err)
	}

	// An unshared record must write no "shared" key at all: every record
	// already on disk predates this field and must survive a rewrite
	// byte-identical.
	raw, err := os.ReadFile(filepath.Join(home, ".wakil/orgs/initech/providers/main.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "shared") {
		t.Errorf("an unshared provider record wrote a \"shared\" key: %s", raw)
	}

	p, err := LoadProviderFor("initech", "main")
	if err != nil {
		t.Fatal(err)
	}
	if p.Shared {
		t.Error("a record with no \"shared\" key loaded as Shared=true")
	}
}

func TestConfigDirHomeSkipsSharedRecordsRegardlessOfOrgOrder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// "alpha" sorts before "zulu", and ListOrgs sorts. The SHARED record is
	// deliberately the one that sorts first, so a ConfigDirHome that simply
	// returned the first match would pass this test for the wrong reason.
	for _, org := range []string{"alpha", "zulu"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(home, ".claude-shared")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	// zulu homes it; alpha only shares it. Written directly rather than
	// through AddProvider, which does not learn --share until Task 2.
	writeProviderRecord(t, home, "zulu", "home-acct", Provider{
		Kind: ProviderKindClaudeCode, ConfigDir: cfg,
	})
	writeProviderRecord(t, home, "alpha", "shared-acct", Provider{
		Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
	})

	org, id, err := ConfigDirHome(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if org != "zulu" || id != "home-acct" {
		t.Errorf("ConfigDirHome = (%q, %q); want (\"zulu\", \"home-acct\")", org, id)
	}

	// The unfiltered lookup still sees every record — AddProvider's
	// --share branch depends on it to tell "never registered" apart from
	// "homed record deleted, orphaned sharers left behind". It is NOT what
	// the same-org duplicate check uses: that asks findConfigDirInOrg,
	// because this call's answer here is "alpha" for a question about zulu.
	org, id, err = findConfigDirOwner(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	if org != "alpha" || id != "shared-acct" {
		t.Errorf("findConfigDirOwner(homeOnly=false) = (%q, %q); want the first match (\"alpha\", \"shared-acct\")", org, id)
	}
}

func TestConfigDirHomeReportsNoneForAnUnclaimedDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	org, id, err := ConfigDirHome(filepath.Join(home, ".claude-nobody"))
	if err != nil {
		t.Fatal(err)
	}
	if org != "" || id != "" {
		t.Errorf("ConfigDirHome on an unclaimed dir = (%q, %q); want two empty strings", org, id)
	}
}

// The four cross-org rows of the design's §4.2 matrix, plus the same-org
// row, one subtest each. The matrix is the specification; this is it
// executed.
func TestAddProviderShareMatrix(t *testing.T) {
	t.Run("another org owns it, no --share: refused, and the message names --share", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		for _, org := range []string{"initech", "personal"} {
			if err := CreateOrg(org, Org{}); err != nil {
				t.Fatal(err)
			}
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

		err := AddProvider("personal", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg})
		if err == nil {
			t.Fatal("AddProvider accepted a configDir owned by another org without --share")
		}
		// The operator's next question is "so how DO I use this account
		// here?", and the refusal must answer it without a second command.
		for _, want := range []string{`"initech"`, `"main"`, "--share"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("refusal must contain %s; got %q", want, err)
			}
		}
		if _, err := LoadProviderFor("personal", "work"); err == nil {
			t.Error("a refused AddProvider still wrote a provider record")
		}
	})

	t.Run("another org owns it, with --share: accepted and marked shared", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		for _, org := range []string{"initech", "personal"} {
			if err := CreateOrg(org, Org{}); err != nil {
				t.Fatal(err)
			}
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

		if err := AddProvider("personal", Provider{
			ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		}); err != nil {
			t.Fatalf("AddProvider refused a legitimate --share: %v", err)
		}
		p, err := LoadProviderFor("personal", "work")
		if err != nil {
			t.Fatal(err)
		}
		if !p.Shared {
			t.Error("a --share registration did not persist Shared=true")
		}
		// The home does not move.
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "initech" || id != "main" {
			t.Errorf("sharing moved the home to (%q, %q); it must stay (\"initech\", \"main\")", org, id)
		}
	})

	// **This subtest asserted a refusal until 2e (#201), and the ruling
	// that reversed it is recorded here rather than in a deleted case.**
	//
	// Adding a binding to a config dir NOTHING HOMES now makes that
	// binding the home. It is one of the two changes in the ADD path that
	// let #206 drop `RemoveProvider`'s orphan refusal — a refusal resting
	// on a claim that was measured false — and none is made in the remove
	// path. The case it rescues is a home record deleted by hand out from
	// under its sharers: under the old rule those orphans could not be
	// re-homed by adding a binding, and the settings pane's Adopt control
	// has no `--share` to drop because every adoption it performs sets it.
	//
	// The cost is named in AddProvider's own comment: the record says it
	// pinned WAKIL_ORG inside the directory and nothing here writes that
	// pin, so the two disagree until `scripts/register-provider.sh` runs
	// for it. Wakil's own sessions never read the pin; a plain `claude`
	// session started there does.
	t.Run("nobody owns it, with --share: becomes the home", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		if err := CreateOrg("personal", Org{}); err != nil {
			t.Fatal(err)
		}
		cfg := filepath.Join(home, ".claude-fresh")
		if err := os.MkdirAll(cfg, 0o755); err != nil {
			t.Fatal(err)
		}
		// Resolved, because AddProvider stores the resolved path and
		// ConfigDirHome compares against what is stored. On macOS
		// t.TempDir() hands back a /var path that resolves to /private/var,
		// so an unresolved cfg here matches nothing and the assertion
		// below would fail for a reason that has nothing to do with the
		// rule under test.
		cfg, err := filepath.EvalSymlinks(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if err := AddProvider("personal", Provider{
			ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		}); err != nil {
			t.Fatalf("AddProvider refused a dir nothing homes: %v", err)
		}
		p, err := LoadProviderFor("personal", "work")
		if err != nil {
			t.Fatal(err)
		}
		// Shared is CLEARED rather than left set: a record claiming to
		// share a directory nothing homes is exactly the shape
		// ResolveProviderClaudePath has no answer for.
		if p.Shared {
			t.Error("a binding that became the home is still marked shared")
		}
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "personal" || id != "work" {
			t.Errorf("home = (%q, %q); want (\"personal\", \"work\")", org, id)
		}
	})

	// The orphaned-sharers case, which is what the rule above actually
	// exists for: a home record deleted by hand, leaving a sharer behind.
	// Adding a binding to that directory re-homes it, and the surviving
	// sharer resolves again.
	t.Run("only sharers name it: the new binding becomes the home", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		for _, org := range []string{"initech", "personal", "third"} {
			if err := CreateOrg(org, Org{}); err != nil {
				t.Fatal(err)
			}
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")
		if err := AddProvider("personal", Provider{
			ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		}); err != nil {
			t.Fatal(err)
		}
		// The home record, removed by hand — which is how this state is
		// reached at all.
		providers, err := providersDirFor("initech")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(providers, "main.json")); err != nil {
			t.Fatal(err)
		}
		if org, id, err := ConfigDirHome(cfg); err != nil || org != "" || id != "" {
			t.Fatalf("the directory still reports a home: (%q, %q, %v)", org, id, err)
		}

		// With a claudePath, which is the OTHER of #201's two add-path
		// changes: adoption records the resolved agent binary, so a
		// binding that becomes the home can answer for the sharers that
		// inherit from it. Without it the re-home succeeds and the sharer
		// still does not resolve — which is the state this pair of
		// changes exists to make unreachable.
		if err := AddProvider("third", Provider{
			ID: "rehome", Kind: ProviderKindClaudeCode, ConfigDir: cfg,
			Shared: true, ClaudePath: "/usr/local/bin/claude",
		}); err != nil {
			t.Fatalf("AddProvider refused to re-home an orphaned directory: %v", err)
		}
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "third" || id != "rehome" {
			t.Errorf("home = (%q, %q); want (\"third\", \"rehome\")", org, id)
		}
		// And the surviving sharer resolves again, which is the whole
		// point: it inherits its agent binary from the home.
		sharer, err := LoadProviderFor("personal", "work")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ResolveProviderClaudePath(*sharer); err != nil {
			t.Errorf("the orphaned sharer still does not resolve: %v", err)
		}
	})

	t.Run("the same org owns it, with --share: refused with its own message", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		if err := CreateOrg("initech", Org{}); err != nil {
			t.Fatal(err)
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

		err := AddProvider("initech", Provider{
			ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		})
		if err == nil {
			t.Fatal("--share let one org register the same configDir twice")
		}
		// Not the generic cross-org message: within one org WAKIL_PROVIDER
		// would collide, and a second id buys no second account and no
		// second quota, which is the entire point of the feature.
		if !strings.Contains(err.Error(), "same org") {
			t.Errorf("the same-org refusal must say so in its own words; got %q", err)
		}
		// The exact phrase the cross-org message uses to legitimately
		// suggest sharing, not the bare "--share": the config dir this
		// subtest's own name feeds into t.TempDir() is quoted inside the
		// refusal too, and a subtest named with "--share" would make a
		// bare-substring check match that quoted path instead of the
		// message text.
		if strings.Contains(err.Error(), "re-run with --share") {
			t.Errorf("the same-org refusal must not suggest --share, which cannot help; got %q", err)
		}
		if _, err := LoadProviderFor("initech", "second"); err == nil {
			t.Error("a refused AddProvider still wrote a provider record")
		}
	})

	t.Run("nobody owns it, no --share: registered as the home", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		if err := CreateOrg("initech", Org{}); err != nil {
			t.Fatal(err)
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "initech" || id != "main" {
			t.Errorf("ConfigDirHome = (%q, %q); want (\"initech\", \"main\")", org, id)
		}
	})
}

// TestAddProviderRefusesASecondRecordInAnOrgThatAlreadyNamesTheDir is the
// regression test for the defect TestAddProviderShareMatrix could not see.
//
// That matrix has a "same org owns it, with --share: refused" row, and it
// passes with exactly ONE record on disk for the config dir. The bug needs
// TWO: a home in one org and a sharer in another. AddProvider used to ask
// findConfigDirOwner(dir, false) — first match in ListOrgs sort order —
// and branch on whether that single answer's org was this one. With
// "alpha" sharing and "zulu" homing, an add into ZULU got back ("alpha",
// the sharer): the same-org branch did not fire (the orgs differed), the
// cross-org branch was skipped (--share was set), and the add fell
// through and wrote zulu a second record for its own config dir.
//
// The org names are load-bearing, as in
// TestConfigDirHomeSkipsSharedRecordsRegardlessOfOrgOrder: "alpha" sorts
// first and is the SHARER, so the wrong answer is the one a first-match
// scan returns.
func TestAddProviderRefusesASecondRecordInAnOrgThatAlreadyNamesTheDir(t *testing.T) {
	// setup builds the two-record fixture and returns the resolved dir.
	setup := func(t *testing.T) (home, cfg string) {
		t.Helper()
		home = t.TempDir()
		t.Setenv("HOME", home)
		for _, org := range []string{"alpha", "zulu"} {
			if err := CreateOrg(org, Org{}); err != nil {
				t.Fatal(err)
			}
		}
		cfg = addClaudeProvider(t, home, "zulu", "home-acct", ".claude-shared")
		if err := AddProvider("alpha", Provider{
			ID: "shared-acct", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		}); err != nil {
			t.Fatalf("fixture: AddProvider refused a legitimate share: %v", err)
		}
		return home, cfg
	}

	// assertSameOrgRefusal checks the refusal is the same-org one and not
	// the cross-org one, and that nothing was written.
	assertSameOrgRefusal := func(t *testing.T, err error, org, id, existing string) {
		t.Helper()
		if err == nil {
			t.Fatalf("AddProvider let org %q register the same configDir twice", org)
		}
		if !strings.Contains(err.Error(), "same org") {
			t.Errorf("refusal must say it is a same-org duplicate; got %q", err)
		}
		if !strings.Contains(err.Error(), strconv.Quote(existing)) {
			t.Errorf("refusal must name the record already holding the dir (%q); got %q", existing, err)
		}
		// A refusal names the fix, and the fix here is to release THIS
		// org's own record — not some other org's.
		if !strings.Contains(err.Error(), "wakil provider rm "+existing+" --org "+org) {
			t.Errorf("refusal must name the release command for this org; got %q", err)
		}
		if strings.Contains(err.Error(), "re-run with --share") {
			t.Errorf("--share cannot rescue a same-org duplicate and must not be suggested; got %q", err)
		}
		if _, err := LoadProviderFor(org, id); err == nil {
			t.Errorf("a refused AddProvider still wrote %s/%s", org, id)
		}
	}

	t.Run("the org that homes it, with --share, while another org shares it", func(t *testing.T) {
		home, cfg := setup(t)
		_ = home
		err := AddProvider("zulu", Provider{
			ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		})
		assertSameOrgRefusal(t, err, "zulu", "second", "home-acct")

		// And the home has not moved, which is the other thing a stray
		// second record in the homing org would have put in doubt.
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "zulu" || id != "home-acct" {
			t.Errorf("ConfigDirHome = (%q, %q); want (\"zulu\", \"home-acct\")", org, id)
		}
	})

	t.Run("the org that homes it, no --share, while another org shares it", func(t *testing.T) {
		_, cfg := setup(t)
		err := AddProvider("zulu", Provider{ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: cfg})
		assertSameOrgRefusal(t, err, "zulu", "second", "home-acct")
	})

	t.Run("the org that already shares it, with --share", func(t *testing.T) {
		_, cfg := setup(t)
		err := AddProvider("alpha", Provider{
			ID: "again", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		})
		assertSameOrgRefusal(t, err, "alpha", "again", "shared-acct")
	})
}

// TestAddProviderCrossOrgRefusalNamesTheHomeAndNotAnotherSharer is the
// second half of the same defect: the message.
//
// With zulu homing and alpha sharing, a third org adding without --share
// was told the dir belonged to "alpha" — which pins nothing, is not the
// org a plain `claude` session there runs as, and whose record the
// suggested `wakil provider rm` would have deleted while releasing
// nothing at all. Every factual claim in the sentence was false. The
// refusal must name the HOME.
func TestAddProviderCrossOrgRefusalNamesTheHomeAndNotAnotherSharer(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"alpha", "mid", "zulu"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := addClaudeProvider(t, home, "zulu", "home-acct", ".claude-shared")
	if err := AddProvider("alpha", Provider{
		ID: "shared-acct", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
	}); err != nil {
		t.Fatal(err)
	}

	err := AddProvider("mid", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg})
	if err == nil {
		t.Fatal("AddProvider accepted a shared configDir without --share")
	}
	for _, want := range []string{`"zulu"`, `"home-acct"`, "--share",
		"wakil provider rm home-acct --org zulu"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal must contain %s; got %q", want, err)
		}
	}
	// The sharer must appear nowhere in it: naming alpha here is the
	// defect, not a harmless extra detail.
	for _, unwanted := range []string{"alpha", "shared-acct"} {
		if strings.Contains(err.Error(), unwanted) {
			t.Errorf("refusal must not name the sharer %q; got %q", unwanted, err)
		}
	}
}

// TestRemoveProviderRefusesWhileOtherOrgsShareTheConfigDir is the
// regression test for the one-way door.
//
// Removing a home record used to succeed unconditionally, after which
// ConfigDirHome returned "" forever: `provider add` without --share was
// refused (the orphaned sharers still named the dir), `--share` was
// refused (nothing homed it), and register-provider.sh — which asks
// `provider home` before every `claude mcp add` — could never run for
// that dir again. One command, no way back.
func TestRemoveProviderRefusesWhileOtherOrgsShareTheConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"alpha", "zulu"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := addClaudeProvider(t, home, "zulu", "home-acct", ".claude-shared")
	if err := AddProvider("alpha", Provider{
		ID: "shared-acct", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
	}); err != nil {
		t.Fatal(err)
	}

	err := RemoveProvider("zulu", "home-acct")
	if err == nil {
		t.Fatal("RemoveProvider deleted a home record while another org still shared its config dir")
	}
	// Naming the dependents is the whole point, exactly as RemoveOrg
	// names the provider count it refuses on.
	for _, want := range []string{"alpha/shared-acct", cfg, "wakil provider rm"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal must contain %q; got %q", want, err)
		}
	}
	if _, err := LoadProviderFor("zulu", "home-acct"); err != nil {
		t.Fatalf("a refused RemoveProvider removed the record anyway: %v", err)
	}
	if org, id, err := ConfigDirHome(cfg); err != nil || org != "zulu" || id != "home-acct" {
		t.Errorf("ConfigDirHome = (%q, %q, %v); the home must survive a refused removal", org, id, err)
	}

	// The refusal names a route out, so walk it: remove the sharer, then
	// the home. A refusal whose instruction does not work is the defect
	// this test also exists to prevent (runProviderHome shipped one).
	if err := RemoveProvider("alpha", "shared-acct"); err != nil {
		t.Fatalf("RemoveProvider refused a SHARED record, which nothing depends on: %v", err)
	}
	if err := RemoveProvider("zulu", "home-acct"); err != nil {
		t.Fatalf("RemoveProvider still refused the home after its last sharer was gone: %v", err)
	}
}

// TestRemoveProviderStillRemovesARecordNothingDependsOn is the control
// for the test above: without it, that suite would pass if RemoveProvider
// refused everything.
func TestRemoveProviderStillRemovesARecordNothingDependsOn(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	addClaudeProvider(t, home, "initech", "main", ".claude-initech")
	if err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"main", "cx"} {
		if err := RemoveProvider("initech", id); err != nil {
			t.Errorf("RemoveProvider(%q) refused a record nothing shares: %v", id, err)
		}
	}
}

// TestAddProviderRefusesShareOnAKindWithNoConfigDir is the regression
// test for a flag that said "--kind claude-code only" and was enforced
// nowhere.
//
// `--share --kind codex` was accepted and stored `"shared": true` on a
// record with an empty ConfigDir. `wakil provider add` then asked
// ConfigDirHome(""), whose scan matched every record storing "" — every
// codex and local provider on the machine — and printed a sentence about
// an unrelated provider pinning WAKIL_ORG inside a path it left blank.
// Both halves are covered here: the flag is refused, and the lookup
// answers nothing for an empty dir.
func TestAddProviderRefusesShareOnAKindWithNoConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("alpha", Org{}); err != nil {
		t.Fatal(err)
	}
	// An existing record with an empty ConfigDir, which is what
	// ConfigDirHome("") used to match.
	if err := AddProvider("alpha", Provider{ID: "c1", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}

	for _, kind := range []string{ProviderKindCodex, ProviderKindLocal} {
		err := AddProvider("alpha", Provider{ID: "shared-" + kind, Kind: kind, Shared: true})
		if err == nil {
			t.Fatalf("AddProvider accepted --share on --kind %s, which has no config dir to share", kind)
		}
		if !strings.Contains(err.Error(), ProviderKindClaudeCode) {
			t.Errorf("the refusal must say which kind --share does apply to; got %q", err)
		}
		if _, err := LoadProviderFor("alpha", "shared-"+kind); err == nil {
			t.Errorf("a refused AddProvider still wrote a %s record", kind)
		}
	}

	// The second defence: an empty dir is owned by nobody, however many
	// records store "".
	if org, id, err := ConfigDirHome(""); err != nil || org != "" || id != "" {
		t.Errorf("ConfigDirHome(\"\") = (%q, %q, %v); an empty path has no home", org, id, err)
	}
	if org, id, err := findConfigDirOwner("", false); err != nil || org != "" || id != "" {
		t.Errorf("findConfigDirOwner(\"\", false) = (%q, %q, %v); an empty path has no owner", org, id, err)
	}
}

// resolveClaudePathFixture builds the one arrangement every test below
// needs: org `home` homing configDir, and org `sharer` sharing it. It
// returns the sharing record, loaded from disk rather than constructed,
// so what the tests resolve is what AddProvider actually wrote.
func resolveClaudePathFixture(t *testing.T, homePath string) *Provider {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	for _, org := range []string{"home", "sharer"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", org, err)
		}
	}
	configDir := t.TempDir()
	if err := AddProvider("home", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: configDir, ClaudePath: homePath,
	}); err != nil {
		t.Fatalf("AddProvider home: %v", err)
	}
	if err := AddProvider("sharer", Provider{
		ID: "home-main", Kind: ProviderKindClaudeCode, ConfigDir: configDir, Shared: true,
	}); err != nil {
		t.Fatalf("AddProvider share: %v", err)
	}
	shared, err := LoadProviderFor("sharer", "home-main")
	if err != nil {
		t.Fatalf("LoadProviderFor: %v", err)
	}
	return shared
}

func TestResolveProviderClaudePathInheritsFromTheHomingRecord(t *testing.T) {
	shared := resolveClaudePathFixture(t, "/opt/bin/claude")
	got, err := ResolveProviderClaudePath(*shared)
	if err != nil {
		t.Fatalf("ResolveProviderClaudePath: %v", err)
	}
	if got != "/opt/bin/claude" {
		t.Fatalf("ResolveProviderClaudePath = %q, want the homing record's /opt/bin/claude", got)
	}
}

func TestResolveProviderClaudePathPrefersTheRecordsOwnValue(t *testing.T) {
	shared := resolveClaudePathFixture(t, "/opt/bin/claude")
	shared.ClaudePath = "/usr/local/bin/claude"
	got, err := ResolveProviderClaudePath(*shared)
	if err != nil {
		t.Fatalf("ResolveProviderClaudePath: %v", err)
	}
	if got != "/usr/local/bin/claude" {
		t.Fatalf("ResolveProviderClaudePath = %q; an explicit claudePath must beat the inherited one", got)
	}
}

func TestResolveProviderClaudePathLeavesAHomingRecordEmpty(t *testing.T) {
	resolveClaudePathFixture(t, "")
	home, err := LoadProviderFor("home", "main")
	if err != nil {
		t.Fatalf("LoadProviderFor: %v", err)
	}
	got, err := ResolveProviderClaudePath(*home)
	if err != nil {
		t.Fatalf("ResolveProviderClaudePath: %v", err)
	}
	if got != "" {
		t.Fatalf("ResolveProviderClaudePath = %q; a record that homes its own dir has nothing to inherit from", got)
	}
}

func TestResolveProviderClaudePathNamesTheHomeWhenTheHomeIsAlsoEmpty(t *testing.T) {
	shared := resolveClaudePathFixture(t, "")
	_, err := ResolveProviderClaudePath(*shared)
	if err == nil {
		t.Fatal("ResolveProviderClaudePath accepted a share whose home carries no claudePath")
	}
	for _, want := range []string{"home", "main"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal must name the record to fix; %q is missing %q", err, want)
		}
	}
}

func TestResolveProviderClaudePathRefusesAnOrphanedShare(t *testing.T) {
	shared := resolveClaudePathFixture(t, "/opt/bin/claude")
	dir, err := providersDirFor("home")
	if err != nil {
		t.Fatal(err)
	}
	// By hand: RemoveProvider refuses to orphan a share, so only an
	// operator editing ~/.wakil directly can produce this state.
	if err := os.Remove(filepath.Join(dir, "main.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolveProviderClaudePath(*shared); err == nil {
		t.Fatal("ResolveProviderClaudePath resolved a share whose homing record is gone")
	}
}

func TestListAllProvidersSpansEveryOrgAndCarriesNoCredential(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"personal", "work"} {
		if err := CreateOrg(id, Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}
	dir := filepath.Join(home, "cfg-main")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := AddProvider("personal", Provider{ID: "main", Kind: "claude-code", ConfigDir: dir}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	got, err := ListAllProviders()
	if err != nil {
		t.Fatalf("ListAllProviders: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
	if got[0].Org != "personal" || got[0].ID != "main" {
		t.Errorf("got %+v, want personal/main", got[0])
	}
	if got[0].HomeOrg != "personal" {
		t.Errorf("HomeOrg = %q, want personal", got[0].HomeOrg)
	}
}
