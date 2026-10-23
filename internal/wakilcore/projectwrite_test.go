package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NOTE. Every test here points `securityBinary` at a fake, so no DSN
// reaches the operator's real login keychain.

func projectFixture(t *testing.T, org string, raw string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "project.json")
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestAHandAuthoredProjectFileSurvivesAWrite is **the phase's one owed Go
// test** (the spec's Testing Decisions), and it is owed because
// `project.json` has no writer today: the runbooks hand-author it in full,
// and this phase authors the product's first writer for it.
//
// What it pins is read-modify-write FROM DISK: a file the operator wrote
// by hand keeps everything the write did not touch.
func TestAHandAuthoredProjectFileSurvivesAWrite(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}

	// Hand-authored, the way a runbook writes one: several roots, a PM
	// scope, two environments, and an API entry — none of which the DSN
	// write below has any business touching.
	path := projectFixture(t, "acme", `{
  "name": "orders",
  "org": "acme",
  "roots": [
    {"path": "/src/orders", "role": "service"},
    {"path": "/src/orders-web", "role": "web"}
  ],
  "scopes": {"pm": {"provider": "jira", "projectKey": "ORD"}},
  "environments": {
    "staging": {
      "databases": [{"name": "core", "driver": "mysql", "ref": "db:hand-written"}],
      "api": [{"name": "core", "baseUrl": "https://api.staging.test", "authRef": "api:staging"}]
    },
    "production": {"databases": []}
  }
}`)

	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://user:pw@db.internal:3306/orders",
	}); err != nil {
		t.Fatal(err)
	}

	after, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}

	// Everything the write did not touch survives.
	if len(after.Roots) != 2 || after.Roots[1].Path != "/src/orders-web" {
		t.Errorf("roots did not survive: %+v", after.Roots)
	}
	if after.Scopes.PM == nil || after.Scopes.PM.ProjectKey != "ORD" {
		t.Errorf("the PM scope did not survive: %+v", after.Scopes)
	}
	staging := after.Environments["staging"]
	if len(staging.API) != 1 || staging.API[0].BaseURL != "https://api.staging.test" {
		t.Errorf("the API entry did not survive: %+v", staging.API)
	}
	if _, ok := after.Environments["production"]; !ok {
		t.Error("the other environment did not survive")
	}

	// And the one thing that did change, changed: the ref is DERIVED,
	// replacing whatever was hand-written there.
	if len(staging.Databases) != 1 {
		t.Fatalf("databases = %+v", staging.Databases)
	}
	if want := DatabaseRef("orders", "staging", "core"); staging.Databases[0].Ref != want {
		t.Errorf("ref = %q; want the derived %q", staging.Databases[0].Ref, want)
	}
}

// TestUnknownKeysDropOnAWrite — the cost of the writer above, stated
// rather than discovered. The charter permits it (§1) and every other
// reader in this package behaves the same way; what matters is that it is
// a known cost with a test naming it.
func TestUnknownKeysDropOnAWrite(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme", `{
  "name": "orders",
  "org": "acme",
  "somethingThisBuildDoesNotKnowAbout": {"kept": true},
  "environments": {"staging": {"databases": []}}
}`)

	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://user:pw@db/orders",
	}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "somethingThisBuildDoesNotKnowAbout") {
		t.Error("an unknown key survived; this test records that it does NOT, so update the " +
			"charter note rather than deleting this test")
	}
}

// TestTheDSNNeverReachesTheProjectFile. What lands on disk is the
// database's name, driver and REF — a Keychain entry name, not a secret.
// That split is why a config file can be read, copied and hand-edited at
// all.
func TestTheDSNNeverReachesTheProjectFile(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)

	const dsn = "mysql://root:hunter2@db.internal:3306/orders"
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: dsn,
	}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, fragment := range []string{"hunter2", "root:", dsn} {
		if strings.Contains(string(raw), fragment) {
			t.Errorf("the project file contains %q:\n%s", fragment, raw)
		}
	}

	// It IS in the Keychain, under the derived ref.
	stored, err := SecretGetFor("acme", DatabaseRef("orders", "staging", "core"))
	if err != nil {
		t.Fatal(err)
	}
	if stored != dsn {
		t.Errorf("stored = %q", stored)
	}
}

// TestGrantingWriteAccessNeedsItsOwnCredential. `writeRef` names a SECOND
// credential the database server granted — write authority proven to the
// server rather than asserted by Wakil to itself. It is never the read
// credential with a flag set.
func TestGrantingWriteAccessNeedsItsOwnCredential(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)

	// Asking for write with no second credential is refused.
	err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://ro@db/orders", GrantWrite: true,
	})
	if err == nil {
		t.Fatal("write access was granted without a credential to prove it")
	}
	if !strings.Contains(err.Error(), "SECOND credential") {
		t.Errorf("the refusal does not say why: %v", err)
	}

	// With one, both are stored and the row is writable.
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://ro@db/orders",
		GrantWrite: true, WriteDSN: "mysql://rw@db/orders",
	}); err != nil {
		t.Fatal(err)
	}
	project, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	database := project.Environments["staging"].Databases[0]
	if database.WriteRef == "" {
		t.Fatal("writeRef was not recorded")
	}
	if database.WriteRef == database.Ref {
		t.Error("the write credential is the read one under another name")
	}
	stored, err := SecretGetFor("acme", database.WriteRef)
	if err != nil || stored != "mysql://rw@db/orders" {
		t.Errorf("the write credential was not stored: %q, %v", stored, err)
	}
}

// TestSettingADSNDoesNotRevokeWriteAccess. Editing the read credential is
// not a request to un-grant a permission the operator granted
// deliberately.
func TestSettingADSNDoesNotRevokeWriteAccess(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)

	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core", Driver: "mysql",
		DSN: "mysql://ro@db/orders", GrantWrite: true, WriteDSN: "mysql://rw@db/orders",
	}); err != nil {
		t.Fatal(err)
	}
	// A later edit to the READ credential alone.
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core", Driver: "mysql",
		DSN: "mysql://ro2@db/orders",
	}); err != nil {
		t.Fatal(err)
	}

	project, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if project.Environments["staging"].Databases[0].WriteRef == "" {
		t.Error("editing the read credential silently revoked write access")
	}
}

// TestRemovingADatabaseKeepsItsKeychainEntry. **"Unreferenced" is a claim
// the registry has no standing to make** — the same credential may be
// named by another project, a hand-written script, or a colleague's
// checkout, none of which this file can see. The row goes and the secret
// stays, which is recoverable; the reverse is not.
func TestRemovingADatabaseKeepsItsKeychainEntry(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://user:pw@db/orders",
	}); err != nil {
		t.Fatal(err)
	}
	ref := DatabaseRef("orders", "staging", "core")

	if err := RemoveDatabase(path, "staging", "core"); err != nil {
		t.Fatal(err)
	}
	project, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(project.Environments["staging"].Databases) != 0 {
		t.Error("the row was not removed")
	}

	presence, err := SecretPresenceFor("acme", ref)
	if err != nil {
		t.Fatal(err)
	}
	if !presence.Present {
		t.Error("removing a database deleted its Keychain entry")
	}
}

// TestAProjectInAnotherOrganisationIsReadOnlyHere. This pane never writes
// across the boundary that defines an organisation.
func TestAProjectInAnotherOrganisationIsReadOnlyHere(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	for _, org := range []string{"acme", "other"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	path := projectFixture(t, "other",
		`{"name":"elsewhere","org":"other","environments":{"staging":{"databases":[]}}}`)

	err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://user:pw@db/orders",
	})
	if err == nil {
		t.Fatal("a DSN was written into another organisation's project")
	}
	if !strings.Contains(err.Error(), "read-only here") {
		t.Errorf("the refusal does not name the rule: %v", err)
	}

	if err := RemoveDatabase(path, "staging", "core"); err == nil {
		t.Fatal("a database was removed from another organisation's project")
	}
}

// TestSetDatabaseDSNRefusesWhatItCannotStore — an empty connection string
// would store nothing under a ref the row then advertises as present.
func TestSetDatabaseDSNRefusesWhatItCannotStore(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)

	for name, request := range map[string]DatabaseDSNRequest{
		"no dsn":         {ProjectPath: path, Environment: "staging", Name: "core"},
		"no name":        {ProjectPath: path, Environment: "staging", DSN: "mysql://db"},
		"no environment": {ProjectPath: path, Name: "core", DSN: "mysql://db"},
		"unknown environment": {
			ProjectPath: path, Environment: "nope", Name: "core", DSN: "mysql://db",
		},
	} {
		t.Run(name, func(t *testing.T) {
			if err := SetDatabaseDSN(request); err == nil {
				t.Fatalf("accepted %+v", request)
			}
		})
	}
}

// TestSaveProjectRefusesAFileItWouldCorrupt. `LoadProject` refuses a file
// with no name or org, so writing one would produce a file the product
// cannot read back.
func TestSaveProjectRefusesAFileItWouldCorrupt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "project.json")
	if err := SaveProject(path, Project{Name: "orders"}); err == nil {
		t.Fatal("SaveProject wrote a file with no org")
	}
	if err := SaveProject(path, Project{Org: "acme"}); err == nil {
		t.Fatal("SaveProject wrote a file with no name")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("a refused SaveProject still created the file")
	}

	// And a valid one round-trips.
	p := Project{
		Name: "orders", Org: "acme",
		Environments: map[string]Environment{"staging": {Databases: []Database{}}},
	}
	if err := SaveProject(path, p); err != nil {
		t.Fatal(err)
	}
	back, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if back.Name != "orders" || back.Org != "acme" {
		t.Errorf("round trip lost fields: %+v", back)
	}
	// Written indented, like every other file this package writes, so a
	// hand-editing operator meets a file that looks like the ones they
	// wrote.
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var pretty map[string]any
	if err := json.Unmarshal(raw, &pretty); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "\n  ") {
		t.Errorf("the file is not indented:\n%s", raw)
	}
}

// TestARefusedGrantStoresNothing — the review finding. The read
// credential used to be written BEFORE the grant was validated, so a
// request to grant write access with no second credential left a secret
// in the Keychain under a ref no record names.
//
// That is the credential-without-a-record shape `CommitMintedProvider`
// spends a whole check making unreachable for providers, and it breaks
// this package's standing rule that a refused write writes nothing.
func TestARefusedGrantStoresNothing(t *testing.T) {
	fakeKeychain(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)

	err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core",
		Driver: "mysql", DSN: "mysql://ro:pw@db/orders", GrantWrite: true,
	})
	if err == nil {
		t.Fatal("the grant was accepted with no credential to prove it")
	}

	// Nothing stored, under either ref.
	ref := DatabaseRef("orders", "staging", "core")
	for _, candidate := range []string{ref, ref + ":rw"} {
		presence, err := SecretPresenceFor("acme", candidate)
		if err != nil {
			t.Fatal(err)
		}
		if presence.Present {
			t.Errorf("a refused write left a secret at %q", candidate)
		}
	}
	// And no record.
	project, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(project.Environments["staging"].Databases) != 0 {
		t.Error("a refused write still recorded the database")
	}
}

func dbEditSetup(t *testing.T) string {
	t.Helper()
	fakeKeychain(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	return projectFixture(t, "acme", `{"name":"shop","org":"acme","environments":{"staging":{"databases":[
	  {"name":"core","driver":"mysql","ref":"db:shop:staging:core","writeRef":"db:shop:staging:core:rw"},
	  {"name":"orders","driver":"mysql","ref":"db:shop:staging:orders"}]}}}`)
}

func TestUpdateDatabaseRenameKeepsItsRefs(t *testing.T) {
	path := dbEditSetup(t)
	name := "reports"
	if err := UpdateDatabase(path, "staging", "core", DatabaseEdit{NewName: &name}); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadProject(path)
	d := p.Environments["staging"].Databases[0]
	if d.Name != "reports" || d.Ref != "db:shop:staging:core" || d.WriteRef != "db:shop:staging:core:rw" {
		t.Errorf("database = %+v", d)
	}

	clash := "orders"
	if err := UpdateDatabase(path, "staging", "reports", DatabaseEdit{NewName: &clash}); err == nil ||
		!strings.Contains(err.Error(), "orders") {
		t.Errorf("clash = %v", err)
	}
	same := "reports"
	if err := UpdateDatabase(path, "staging", "reports", DatabaseEdit{NewName: &same}); err != nil {
		t.Errorf("rename to its own name: %v", err)
	}
	for _, bad := range []string{"", "a/b"} {
		if err := UpdateDatabase(path, "staging", "reports", DatabaseEdit{NewName: &bad}); err == nil {
			t.Errorf("name %q accepted", bad)
		}
	}
	if err := UpdateDatabase(path, "staging", "nope", DatabaseEdit{}); err == nil ||
		!strings.Contains(err.Error(), `no database "nope" in environment "staging"`) {
		t.Errorf("missing database = %v", err)
	}
	if err := UpdateDatabase(path, "prod", "reports", DatabaseEdit{}); err == nil {
		t.Error("a missing environment was accepted")
	}
}

func TestRevokeWriteKeepsTheKeychainEntry(t *testing.T) {
	path := dbEditSetup(t)
	if err := SecretSetFor("acme", "db:shop:staging:core:rw", "mysql://rw"); err != nil {
		t.Fatal(err)
	}
	if err := UpdateDatabase(path, "staging", "core", DatabaseEdit{RevokeWrite: true}); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadProject(path)
	d := p.Environments["staging"].Databases[0]
	if d.WriteRef != "" || d.Ref != "db:shop:staging:core" || d.Name != "core" {
		t.Errorf("database = %+v", d)
	}
	if got, err := SecretGetFor("acme", "db:shop:staging:core:rw"); err != nil || got != "mysql://rw" {
		t.Errorf("the write credential did not survive: %q, %v", got, err)
	}
}

func TestUpdateDatabaseRefusesAnotherOrganisationsProject(t *testing.T) {
	dbEditSetup(t)
	if err := CreateOrg("other", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "other",
		`{"name":"elsewhere","org":"other","environments":{"staging":{"databases":[{"name":"core","driver":"mysql","ref":"r"}]}}}`)
	err := UpdateDatabase(path, "staging", "core", DatabaseEdit{RevokeWrite: true})
	if err == nil || !strings.Contains(err.Error(), "read-only here") {
		t.Errorf("err = %v", err)
	}
}

// TestANewDatabaseUnderARenamedDatabasesOldNameGetsItsOwnRefs — the same
// finding for databases: a rename keeps `ref` and `writeRef`, so a new
// database under the old name must derive refs nothing else names.
func TestANewDatabaseUnderARenamedDatabasesOldNameGetsItsOwnRefs(t *testing.T) {
	path := dbEditSetup(t)
	for _, ref := range []string{"db:shop:staging:core", "db:shop:staging:core:rw"} {
		if err := SecretSetFor("acme", ref, "old "+ref); err != nil {
			t.Fatal(err)
		}
	}
	renamed := "reports"
	if err := UpdateDatabase(path, "staging", "core", DatabaseEdit{NewName: &renamed}); err != nil {
		t.Fatal(err)
	}
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core", Driver: "mysql",
		DSN: "mysql://ro@new/core", GrantWrite: true, WriteDSN: "mysql://rw@new/core",
	}); err != nil {
		t.Fatal(err)
	}

	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	dbs := p.Environments["staging"].Databases
	if len(dbs) != 3 || dbs[0].Name != "reports" || dbs[2].Name != "core" {
		t.Fatalf("databases = %+v", dbs)
	}
	if dbs[0].Ref != "db:shop:staging:core" || dbs[0].WriteRef != "db:shop:staging:core:rw" {
		t.Errorf("the renamed database's refs moved: %+v", dbs[0])
	}
	if dbs[2].Ref != "db:shop:staging:core:2" || dbs[2].WriteRef != "db:shop:staging:core:2:rw" {
		t.Errorf("the new database's refs = %q / %q; want distinct :2 refs", dbs[2].Ref, dbs[2].WriteRef)
	}
	for ref, want := range map[string]string{
		"db:shop:staging:core":      "old db:shop:staging:core",
		"db:shop:staging:core:rw":   "old db:shop:staging:core:rw",
		"db:shop:staging:core:2":    "mysql://ro@new/core",
		"db:shop:staging:core:2:rw": "mysql://rw@new/core",
	} {
		if got, _ := SecretGetFor("acme", ref); got != want {
			t.Errorf("%s = %q; want %q", ref, got, want)
		}
	}
}

// --- SetDatabaseConnection (2e-iv) ---

// loggedKeychain wraps the fake `security` that fakeKeychain installed in a
// script that appends each subcommand to a log file first. The fake has no
// call log of its own, so this is how "no Keychain write" is asserted: the
// number of add-generic-password calls, not just the stored value.
func loggedKeychain(t *testing.T) (keychainWrites func() int) {
	t.Helper()
	fakeKeychain(t)
	inner := string(securityBinary)
	log := filepath.Join(t.TempDir(), "calls.log")
	wrapper := filepath.Join(t.TempDir(), "security")
	script := "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '" + log + "'\nexec '" + inner + "' \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	securityBinary = keychainTool(wrapper) // fakeKeychain's cleanup restores the original
	return func() int {
		raw, err := os.ReadFile(log)
		if os.IsNotExist(err) {
			return 0
		}
		if err != nil {
			t.Fatal(err)
		}
		return strings.Count(string(raw), "add-generic-password")
	}
}

func connectionFixture(t *testing.T) (path string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	return projectFixture(t, "acme",
		`{"name":"orders","org":"acme","environments":{"staging":{"databases":[]}}}`)
}

func mysqlRequest(path string) DatabaseConnectionRequest {
	return DatabaseConnectionRequest{
		ProjectPath: path, Environment: "staging", Name: "core", Driver: "mysql",
		Connection: DatabaseConnection{Host: "db.internal", Port: "3306", Database: "ledger", User: "e2e"},
		Password:   "hunter2",
	}
}

func storedDatabase(t *testing.T, path, name string) Database {
	t.Helper()
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range p.Environments["staging"].Databases {
		if d.Name == name {
			return d
		}
	}
	t.Fatalf("no database %q stored", name)
	return Database{}
}

func TestTheSplitRecordKeepsOnlyThePasswordInTheKeychain(t *testing.T) {
	loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseConnection(mysqlRequest(path)); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "hunter2") {
		t.Fatalf("the project file holds the password:\n%s", raw)
	}
	d := storedDatabase(t, path, "core")
	if d.Connection == nil || d.Connection.Host != "db.internal" || d.Connection.User != "e2e" ||
		d.Connection.Database != "ledger" {
		t.Fatalf("parts not in the file: %+v", d.Connection)
	}
	if got, err := SecretGet(d.Ref); err != nil || got != "hunter2" {
		t.Fatalf("keychain item = %q, %v; want just the password", got, err)
	}
	if d.WriteRef != "" {
		t.Fatalf("a writeRef appeared without a grant: %q", d.WriteRef)
	}
}

func TestAnEmptyPasswordKeepsTheStoredOne(t *testing.T) {
	writes := loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseConnection(mysqlRequest(path)); err != nil {
		t.Fatal(err)
	}
	before := storedDatabase(t, path, "core")
	n := writes()

	r := mysqlRequest(path)
	r.Password = ""
	r.Connection.Port = "3307"
	if err := SetDatabaseConnection(r); err != nil {
		t.Fatal(err)
	}
	after := storedDatabase(t, path, "core")
	if after.Connection.Port != "3307" {
		t.Fatalf("port not saved: %+v", after.Connection)
	}
	if writes() != n {
		t.Fatalf("the Keychain was written %d time(s) by a save with no password", writes()-n)
	}
	if after.Ref != before.Ref {
		t.Fatalf("ref moved from %q to %q", before.Ref, after.Ref)
	}
	if got, _ := SecretGet(after.Ref); got != "hunter2" {
		t.Fatalf("stored password = %q", got)
	}
}

func TestAChangedUserNeedsItsPassword(t *testing.T) {
	writes := loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseConnection(mysqlRequest(path)); err != nil {
		t.Fatal(err)
	}
	n := writes()
	rawBefore, _ := os.ReadFile(path)

	r := mysqlRequest(path)
	r.Password = ""
	r.Connection.User = "other"
	err := SetDatabaseConnection(r)
	msg, ok := IsUserError(err)
	if !ok || msg != "a new user needs its password — the stored one belongs to e2e" {
		t.Fatalf("got %v", err)
	}
	rawAfter, _ := os.ReadFile(path)
	if string(rawBefore) != string(rawAfter) || writes() != n {
		t.Fatal("a refused save wrote something")
	}

	// With the password it goes through.
	r.Password = "newpw"
	if err := SetDatabaseConnection(r); err != nil {
		t.Fatal(err)
	}
	if got, _ := SecretGet(storedDatabase(t, path, "core").Ref); got != "newpw" {
		t.Fatalf("stored password = %q", got)
	}
}

func TestAChangedWriteUserNeedsItsPasswordToo(t *testing.T) {
	writes := loggedKeychain(t)
	path := connectionFixture(t)
	r := mysqlRequest(path)
	r.GrantWrite, r.Connection.WriteUser, r.WritePassword = true, "writer", "writepw"
	if err := SetDatabaseConnection(r); err != nil {
		t.Fatal(err)
	}
	d := storedDatabase(t, path, "core")
	if d.WriteRef == "" || d.Connection.WriteUser != "writer" {
		t.Fatalf("write grant not recorded: %+v", d)
	}
	if got, _ := SecretGet(d.WriteRef); got != "writepw" {
		t.Fatalf("write item = %q", got)
	}
	n := writes()

	// Same write user, no password: kept, no write.
	keep := mysqlRequest(path)
	keep.Password = ""
	keep.GrantWrite, keep.Connection.WriteUser = true, "writer"
	keep.Connection.Port = "3307"
	if err := SetDatabaseConnection(keep); err != nil {
		t.Fatal(err)
	}
	if writes() != n {
		t.Fatal("keeping both passwords still wrote the Keychain")
	}

	// Changed write user, no write password: refused.
	keep.Connection.WriteUser = "writer2"
	msg, ok := IsUserError(SetDatabaseConnection(keep))
	if !ok || msg != "a new user needs its password — the stored one belongs to writer" {
		t.Fatalf("got %q", msg)
	}

	// A save that does not grant keeps the writeRef and the write user.
	r2 := mysqlRequest(path)
	r2.Password = ""
	if err := SetDatabaseConnection(r2); err != nil {
		t.Fatal(err)
	}
	d = storedDatabase(t, path, "core")
	if d.WriteRef == "" || d.Connection.WriteUser != "writer" {
		t.Fatalf("a save without a grant dropped the write access: %+v %+v", d, d.Connection)
	}
}

func TestAGrantWithNoWriteUserIsRefusedAndWritesNothing(t *testing.T) {
	writes := loggedKeychain(t)
	path := connectionFixture(t)
	r := mysqlRequest(path)
	r.GrantWrite, r.WritePassword = true, "writepw"
	msg, ok := IsUserError(SetDatabaseConnection(r))
	if !ok || !strings.HasPrefix(msg, "allowing writes needs the write login's user") {
		t.Fatalf("got %q", msg)
	}
	if writes() != 0 {
		t.Fatal("a refusal wrote the Keychain")
	}
}

func TestANewRecordNeedsItsPassword(t *testing.T) {
	writes := loggedKeychain(t)
	path := connectionFixture(t)
	r := mysqlRequest(path)
	r.Password = ""
	if _, ok := IsUserError(SetDatabaseConnection(r)); !ok {
		t.Fatal("a new server record was saved with no password")
	}
	if writes() != 0 {
		t.Fatal("a refusal wrote the Keychain")
	}
}

func TestALegacyRecordBecomesSplitWhenEdited(t *testing.T) {
	loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core", Driver: "mysql",
		DSN: "e2e:old@tcp(legacy:3306)/ledger",
	}); err != nil {
		t.Fatal(err)
	}
	legacy := storedDatabase(t, path, "core")
	if legacy.Connection != nil {
		t.Fatal("a DSN record has parts")
	}

	// The legacy item is the whole string, not a password: it is not kept.
	r := mysqlRequest(path)
	r.Password = ""
	if _, ok := IsUserError(SetDatabaseConnection(r)); !ok {
		t.Fatal("a legacy record was converted with no password")
	}
	if got, _ := SecretGet(legacy.Ref); got != "e2e:old@tcp(legacy:3306)/ledger" {
		t.Fatalf("the refused edit touched the legacy item: %q", got)
	}

	if err := SetDatabaseConnection(mysqlRequest(path)); err != nil {
		t.Fatal(err)
	}
	d := storedDatabase(t, path, "core")
	if d.Connection == nil || d.Connection.Host != "db.internal" {
		t.Fatalf("not split: %+v", d)
	}
	if got, _ := SecretGet(d.Ref); got != "hunter2" {
		t.Fatalf("item = %q, want the password alone", got)
	}
}

func TestALegacyWritableRecordCannotSilentlyKeepAWholeStringWriteItem(t *testing.T) {
	loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseDSN(DatabaseDSNRequest{
		ProjectPath: path, Environment: "staging", Name: "core", Driver: "mysql",
		DSN: "ro:x@tcp(h:3306)/ledger", GrantWrite: true, WriteDSN: "rw:y@tcp(h:3306)/ledger",
	}); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(path)
	if _, ok := IsUserError(SetDatabaseConnection(mysqlRequest(path))); !ok {
		t.Fatal("converting kept a whole-string write item that the resolver could no longer read")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("a refused edit changed the file")
	}
}

func TestARefusedConnectionWritesNothing(t *testing.T) {
	writes := loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseConnection(mysqlRequest(path)); err != nil {
		t.Fatal(err)
	}
	rawBefore, _ := os.ReadFile(path)
	n := writes()

	r := mysqlRequest(path)
	r.Connection.Port = "0"
	r.Password = "brandnew"
	msg, ok := IsUserError(SetDatabaseConnection(r))
	if !ok || msg != "the port must be a number from 1 to 65535" {
		t.Fatalf("got %v", msg)
	}
	rawAfter, _ := os.ReadFile(path)
	if string(rawBefore) != string(rawAfter) {
		t.Fatal("the file changed")
	}
	if writes() != n {
		t.Fatal("the Keychain was written")
	}
	if got, _ := SecretGet(storedDatabase(t, path, "core").Ref); got != "hunter2" {
		t.Fatalf("stored password = %q", got)
	}

	// A bad write login refuses with its prefix, also before any write.
	r = mysqlRequest(path)
	r.GrantWrite, r.WritePassword = true, "w"
	r.Connection.WriteUser = "a:b"
	msg, ok = IsUserError(SetDatabaseConnection(r))
	if !ok || !strings.HasPrefix(msg, "the write login: a MySQL user cannot contain") {
		t.Fatalf("got %q", msg)
	}
	if writes() != n {
		t.Fatal("the Keychain was written")
	}
}

func TestASQLitePathIsInTheFileAndTheKeychain(t *testing.T) {
	loggedKeychain(t)
	path := connectionFixture(t)
	r := DatabaseConnectionRequest{
		ProjectPath: path, Environment: "staging", Name: "lite", Driver: "sqlite",
		Connection: DatabaseConnection{Path: "/data/orders.db"}, GrantWrite: true,
	}
	if err := SetDatabaseConnection(r); err != nil {
		t.Fatal(err)
	}
	d := storedDatabase(t, path, "lite")
	if d.Connection == nil || d.Connection.Path != "/data/orders.db" {
		t.Fatalf("path not in the file: %+v", d.Connection)
	}
	if got, _ := SecretGet(d.Ref); got != "/data/orders.db" {
		t.Fatalf("read item = %q", got)
	}
	if got, _ := SecretGet(d.WriteRef); got != "/data/orders.db" {
		t.Fatalf("write item = %q", got)
	}

	// No path: refused with the ported sentence.
	r.Connection.Path = ""
	msg, ok := IsUserError(SetDatabaseConnection(r))
	if !ok || msg != "a SQLite database needs the path to its file" {
		t.Fatalf("got %q", msg)
	}
}

func TestAConnectionForANewDatabaseAfterARenameGetsAFreshRef(t *testing.T) {
	loggedKeychain(t)
	path := connectionFixture(t)
	if err := SetDatabaseConnection(mysqlRequest(path)); err != nil {
		t.Fatal(err)
	}
	renamed := "reports"
	if err := UpdateDatabase(path, "staging", "core", DatabaseEdit{NewName: &renamed}); err != nil {
		t.Fatal(err)
	}
	reportsRef := storedDatabase(t, path, "reports").Ref

	r := mysqlRequest(path)
	r.Password = "other-server-pw"
	if err := SetDatabaseConnection(r); err != nil {
		t.Fatal(err)
	}
	fresh := storedDatabase(t, path, "core")
	if fresh.Ref == reportsRef {
		t.Fatalf("the new core took reports's ref %q", reportsRef)
	}
	if got, _ := SecretGet(reportsRef); got != "hunter2" {
		t.Fatalf("reports's password was overwritten: %q", got)
	}
}

func TestADriverIsRequired(t *testing.T) {
	loggedKeychain(t)
	path := connectionFixture(t)
	r := mysqlRequest(path)
	r.Driver = "postgres"
	if _, ok := IsUserError(SetDatabaseConnection(r)); !ok {
		t.Fatal("an unknown driver was saved")
	}
	r = mysqlRequest(path)
	r.Environment = "nope"
	if _, ok := IsUserError(SetDatabaseConnection(r)); !ok {
		t.Fatal("an unknown environment was accepted")
	}
}
