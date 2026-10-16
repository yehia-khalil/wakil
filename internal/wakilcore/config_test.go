package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadProject(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "project.json")
	os.WriteFile(p, []byte(`{
      "name":"booking-platform","org":"initech",
      "roots":[{"path":"api","role":"service"},{"path":"web-admin","role":"frontend"}],
      "scopes":{"pm":{"provider":"jira","projectKey":"RAF"}},
      "environments":{
        "staging":{"databases":[{"name":"core","driver":"mysql","ref":"bs-core"}],"api":[{"name":"api","baseUrl":"https://staging.internal"}]},
        "production":{"databases":[{"name":"core","driver":"mysql","ref":"bp-core","readOnly":true}]}
      }}`), 0o644)

	proj, err := LoadProject(p)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Name != "booking-platform" || proj.Org != "initech" {
		t.Fatalf("bad header: %+v", proj)
	}
	if len(proj.Roots) != 2 || proj.Roots[0].Path != "api" || proj.Roots[0].Role != "service" {
		t.Fatalf("bad roots: %+v", proj.Roots)
	}
	if proj.Scopes.PM == nil || proj.Scopes.PM.ProjectKey != "RAF" {
		t.Fatalf("bad pm scope: %+v", proj.Scopes)
	}
	// The fixture above still carries "readOnly":true, and that is the
	// assertion: the field was removed on 2026-09-10 (issue #14) and every
	// project.json on disk still has it, so LoadProject must ignore an
	// unknown key rather than fail on one. Nothing reads the value.
	if len(proj.Environments["production"].Databases) != 1 {
		t.Fatalf("a project.json carrying the retired readOnly key must still load its databases")
	}
	staging := proj.Environments["staging"].API
	if len(staging) != 1 || staging[0].Name != "api" || staging[0].BaseURL != "https://staging.internal" {
		t.Fatalf("bad api entries: %+v", staging)
	}
}

// TestNewDatabaseListNeverMarshalsNull asserts the guard NewDatabaseList
// exists for actually fires. A bare DatabaseList{} — or a
// DatabaseList{Databases: nil} built by hand — marshals its nil slice to
// {"databases":null}, which a client iterating the array has to
// special-case. Every wakil-db error path passes nil here precisely
// because this constructor turns it into [].
func TestNewDatabaseListNeverMarshalsNull(t *testing.T) {
	got, err := json.Marshal(NewDatabaseList(nil))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if want := `{"databases":[]}`; string(got) != want {
		t.Errorf("NewDatabaseList(nil) marshals to %s, want %s", got, want)
	}

	dbs := []Database{{Name: "core", Driver: "mysql", Ref: "r"}}
	list := NewDatabaseList(dbs)
	if len(list.Databases) != 1 || list.Databases[0].Name != "core" {
		t.Errorf("NewDatabaseList must project a non-empty slice one-for-one, got %+v", list.Databases)
	}
}

// TestDatabaseListPublishesWritableAndNothingSecret is the whole of issue
// #14 in one assertion. list_databases used to put the on-disk Database
// struct straight on the wire, which published readOnly — a field that
// granted and protected nothing — while hiding writeRef behind omitempty,
// so the one field that decides whether a mutation can run was invisible
// exactly when it was absent. During the 2026-09-10 acceptance run three
// live agent turns read readOnly:true, concluded a write was impossible,
// and declined without calling db_run_mutation at all, so the gate under
// test was never reached.
//
// The wire shape therefore carries what an agent can act on and nothing
// else: name, driver, and a derived writable. The two ref fields are
// Keychain ENTRY NAMES, of no use to an agent and no business of one.
func TestDatabaseListPublishesWritableAndNothingSecret(t *testing.T) {
	list := NewDatabaseList([]Database{
		{Name: "core", Driver: "mysql", Ref: "db:staging"},
		{Name: "orders", Driver: "mysql", Ref: "db:staging", WriteRef: "db:staging:write"},
	})
	got, err := json.Marshal(list)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	want := `{"databases":[` +
		`{"name":"core","driver":"mysql","writable":false},` +
		`{"name":"orders","driver":"mysql","writable":true}` +
		`]}`
	if string(got) != want {
		t.Errorf("list_databases wire shape is\n  %s\nwant\n  %s", got, want)
	}
}

// writable must be present on every entry, never omitempty. An absent
// false is exactly the failure this issue is about: the agent cannot tell
// "not writable" from "this server does not report writability", and the
// safe reading of the second is not the same as the first.
func TestDatabaseInfoAlwaysStatesWritability(t *testing.T) {
	got, err := json.Marshal(DatabaseInfo{Name: "core", Driver: "mysql", Writable: false})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(got), `"writable":false`) {
		t.Errorf("DatabaseInfo must always state writable, got %s", got)
	}
}

// writeRef round-trips, and is omitted entirely when empty so every
// project.json written before Phase 2b-iii stays byte-identical.
func TestDatabaseWriteRefRoundTripsAndOmitsWhenEmpty(t *testing.T) {
	withRef := Database{Name: "orders", Driver: "mysql", Ref: "db:staging", WriteRef: "db:staging:write"}
	b, err := json.Marshal(withRef)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"writeRef":"db:staging:write"`) {
		t.Errorf("writeRef must marshal, got %s", b)
	}
	var back Database
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if back.WriteRef != "db:staging:write" {
		t.Errorf("writeRef must unmarshal, got %q", back.WriteRef)
	}

	without := Database{Name: "orders", Driver: "mysql", Ref: "db:staging"}
	b2, err := json.Marshal(without)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b2), "writeRef") {
		t.Errorf("an empty writeRef must be omitted, got %s", b2)
	}
}
