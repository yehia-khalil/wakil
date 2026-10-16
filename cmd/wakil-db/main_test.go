package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// setupProject writes a minimal project fixture with the given environments
// map (raw JSON fragment, e.g. `"staging":{"databases":[]}`), registers it
// as the active project, and (if envName is non-empty) selects envName as
// the active environment. It fails the test hard on any setup error so a
// broken fixture can never produce a green test.
func setupProject(t *testing.T, environmentsJSON, envName string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	pdir := filepath.Join(home, "proj")
	if err := os.MkdirAll(filepath.Join(pdir, ".wakil"), 0o755); err != nil {
		t.Fatalf("mkdir project dir: %v", err)
	}
	pp := filepath.Join(pdir, ".wakil", "project.json")
	body := `{"name":"proj","org":"initech","roots":[{"path":"."}],"environments":{` + environmentsJSON + `}}`
	if err := os.WriteFile(pp, []byte(body), 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}

	if err := wakilcore.SaveRegistry("initech", map[string]wakilcore.ProjectEntry{"proj": {Path: pp}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}
	if err := wakilcore.SetProjectChecked("proj"); err != nil {
		t.Fatalf("SetProjectChecked: %v", err)
	}
	if envName != "" {
		active, err := wakilcore.ReadActive()
		if err != nil {
			t.Fatalf("ReadActive: %v", err)
		}
		active.Environment = envName
		if err := wakilcore.WriteActive(active); err != nil {
			t.Fatalf("WriteActive: %v", err)
		}
	}
}

// wantUserError fails t unless err is a wakilcore.UserError whose message
// contains want. Asserting the message (not merely "an error occurred") is
// what keeps these tests from passing on the wrong failure — in particular
// it is what stops a test from silently accepting the case where
// PickDatabase's guard is broken and control falls through into
// SecretGet, which would shell out to the real login Keychain.
func wantUserError(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected an error containing %q, got nil", want)
	}
	msg, ok := wakilcore.IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
	if !strings.Contains(msg, want) {
		t.Fatalf("error message %q does not contain %q", msg, want)
	}
}

func TestOpenPickedNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	_, err := openPicked(context.Background(), "")
	wantUserError(t, err, "no active project")
}

func TestOpenPickedAmbiguousDatabaseName(t *testing.T) {
	setupProject(t, `"staging":{"databases":[{"name":"core","driver":"sqlite","ref":"a"},{"name":"events","driver":"sqlite","ref":"b"}]}`, "staging")

	// Empty name with two databases configured must fail during
	// PickDatabase with the specific "multiple databases" message —
	// asserting that exact text (not just "some error happened") is what
	// proves the failure happened in PickDatabase and not, say, further
	// down the call chain in OpenDatabase/SecretGet.
	_, err := openPicked(context.Background(), "")
	wantUserError(t, err, "multiple databases in this environment")
}

func TestOpenPickedUnknownDatabaseName(t *testing.T) {
	setupProject(t, `"staging":{"databases":[{"name":"core","driver":"sqlite","ref":"a"}]}`, "staging")

	_, err := openPicked(context.Background(), "nope")
	wantUserError(t, err, "no database named nope")
}

func TestOpenPickedDuplicateDatabaseName(t *testing.T) {
	setupProject(t, `"staging":{"databases":[{"name":"core","driver":"sqlite","ref":"a"},{"name":"core","driver":"mysql","ref":"b"}]}`, "staging")

	_, err := openPicked(context.Background(), "core")
	wantUserError(t, err, "ambiguous configuration: multiple databases named core")
}

func TestOpenPickedNoEnvironment(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`, "")

	_, err := openPicked(context.Background(), "")
	wantUserError(t, err, "no active environment")
}

func TestNewServerBuilds(t *testing.T) {
	// Smoke test: registering every tool must not panic. Note that
	// duplicate tool *names* do NOT panic here — go-sdk's featureSet.add
	// (mcp/features.go) overwrites an existing entry by name rather than
	// erroring, confirmed by reading the SDK source and experimentally
	// registering two tools named "dup" without a panic. What DOES panic
	// inside AddTool is a bad input/output schema (mcp/server.go's
	// toolForErr / AddTool wrapper), which is what this test actually
	// guards against.
	s := newServer()
	if s == nil {
		t.Fatal("newServer returned nil")
	}
}

// connectedClient wires newServer() up to an in-memory client session so
// tests can exercise the tool handlers exactly as a real MCP client would:
// through CallTool, over the wire, with the SDK doing argument validation
// and response marshaling. This is what actually executes the handler
// closures registered in newServer (as opposed to calling openPicked
// directly, which never touches the handlers themselves).
func connectedClient(t *testing.T) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	s := newServer()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()

	ss, err := s.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "wakil-db-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// wantNoActiveProject is the exact text wakilcore.Resolve produces (see
// internal/wakilcore/resolve.go) when openPicked's first step,
// ResolveEnvironment, fails because no project is active. All six tools
// below reach ResolveEnvironment before doing anything else (five via
// openPicked, and classify_statement by calling it directly), so with no
// active project every one of them must produce exactly this text.
const wantNoActiveProject = "no active project — run set_project first"

// TestToolHandlersNoActiveProject calls all six registered tools that
// reach ResolveEnvironment through a real MCP client/server round trip
// (CallTool over an in-memory transport) with no active project
// configured, and asserts both IsError=true and the exact error text.
// This is what actually exercises the handler closures: per-function
// coverage on newServer/main was 0% in the version of this suite that
// only called openPicked directly, because the closures passed to
// mcp.AddTool never ran.
func TestToolHandlersNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	cs := connectedClient(t)
	ctx := context.Background()

	cases := []struct {
		tool string
		args map[string]any
	}{
		{"list_databases", map[string]any{}},
		{"list_tables", map[string]any{}},
		{"describe_table", map[string]any{"name": "x"}},
		{"list_columns", map[string]any{}},
		{"query", map[string]any{"query": "select 1"}},
		{"read_table", map[string]any{"name": "x"}},
		{"classify_statement", map[string]any{"statement": "select 1"}},
	}

	for _, c := range cases {
		t.Run(c.tool, func(t *testing.T) {
			res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: c.tool, Arguments: c.args})
			if err != nil {
				t.Fatalf("CallTool(%s): %v", c.tool, err)
			}
			if !res.IsError {
				t.Fatalf("CallTool(%s): expected IsError=true, got result %+v", c.tool, res)
			}
			if len(res.Content) == 0 {
				t.Fatalf("CallTool(%s): expected non-empty Content", c.tool)
			}
			tc, ok := res.Content[0].(*mcp.TextContent)
			if !ok {
				t.Fatalf("CallTool(%s): Content[0] is %T, want *mcp.TextContent", c.tool, res.Content[0])
			}
			if tc.Text != wantNoActiveProject {
				t.Fatalf("CallTool(%s): Content text = %q, want %q", c.tool, tc.Text, wantNoActiveProject)
			}
		})
	}
}

// TestToolHandlersSanitizeNonUserError pins the actual leak this review
// round exists to catch, directly, on the observable that distinguishes
// the two handler shapes for every one of the six tools.
//
// internal/wakilcore.ReadActive returns a raw, unwrapped *json.SyntaxError
// when ~/.wakil/orgs/<org>/active.json is malformed (active.go's json.Unmarshal call),
// and Resolve/ResolveEnvironment (resolve.go) pass that error straight
// through without wrapping it in a wakilcore.UserError. That raw error
// reaches every one of the six tool handlers via openPicked (or, for
// list_databases and classify_statement, via the direct
// wakilcore.ResolveEnvironment() call) — which makes it the one failure
// mode in this suite that is NOT a UserError, and therefore the one case
// where the forbidden `return nil, <zero>, err` shape and the required
// `return mcpx.ToolErr(server, err), <zero>, nil` shape produce
// DIFFERENT Content text: for a UserError, err.Error() is byte-identical
// to what ToolErr emits, so no UserError-only test (like
// TestToolHandlersNoActiveProject above) can tell the two shapes apart.
// Verified by mutation (see task-13-report.md, Fix round 2): this test
// goes red under the forbidden shape on every one of the four tools and
// green on correct code.
//
// COUPLING (read before touching active.go/resolve.go): this test's entire
// pinning power depends on ReadActive NOT wrapping its json.Unmarshal error
// in a UserError. Because `want` is built from an independent Unmarshal of
// the same fixture rather than from ReadActive, any such change makes this
// test go RED rather than quietly pass — verified by mutation for both a
// UserError wrap and an fmt.Errorf("...: %w") wrap. (A %w wrap alone is
// harmless: IsUserError uses errors.As, so a wrapped non-UserError is still
// sanitized.) Do NOT repair a red here by updating `want` to the new text:
// for a UserError the correct and forbidden shapes are byte-identical, so
// the "repaired" test would pin nothing at all. Re-source it from another
// genuine non-UserError leak instead.
func TestToolHandlersSanitizeNonUserError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	wakilDir, err := wakilcore.WakilDir()
	if err != nil {
		t.Fatalf("WakilDir: %v", err)
	}
	if err := os.MkdirAll(wakilDir, 0o755); err != nil {
		t.Fatalf("mkdir wakil dir: %v", err)
	}
	// Truncated JSON: ReadActive's json.Unmarshal fails on this before it
	// ever looks at active.Project, so no project/environment fixture is
	// needed at all.
	malformed := []byte(`{"project": `)
	orgDir, err := wakilcore.OrgDir()
	if err != nil {
		t.Fatalf("OrgDir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(orgDir, "active.json"), malformed, 0o644); err != nil {
		t.Fatalf("write malformed active.json: %v", err)
	}

	// Compute the exact raw error text ReadActive will surface by doing
	// the same json.Unmarshal ourselves, rather than hardcoding a message
	// that could drift across Go versions.
	var v wakilcore.ActiveContext
	rawErr := json.Unmarshal(malformed, &v)
	if rawErr == nil {
		t.Fatal("test fixture bug: malformed JSON did not actually fail to unmarshal")
	}
	if _, ok := rawErr.(*json.SyntaxError); !ok {
		t.Fatalf("test fixture bug: expected a *json.SyntaxError (a non-UserError), got %T: %v", rawErr, rawErr)
	}
	want := "wakil-db: an internal error occurred: " + rawErr.Error()

	cs := connectedClient(t)
	ctx := context.Background()

	cases := []struct {
		tool string
		args map[string]any
	}{
		{"list_databases", map[string]any{}},
		{"list_tables", map[string]any{}},
		{"describe_table", map[string]any{"name": "x"}},
		{"list_columns", map[string]any{}},
		{"query", map[string]any{"query": "select 1"}},
		{"read_table", map[string]any{"name": "x"}},
		{"classify_statement", map[string]any{"statement": "select 1"}},
	}

	for _, c := range cases {
		t.Run(c.tool, func(t *testing.T) {
			res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: c.tool, Arguments: c.args})
			if err != nil {
				t.Fatalf("CallTool(%s): %v", c.tool, err)
			}
			if !res.IsError {
				t.Fatalf("CallTool(%s): expected IsError=true, got result %+v", c.tool, res)
			}
			if len(res.Content) == 0 {
				t.Fatalf("CallTool(%s): expected non-empty Content", c.tool)
			}
			tc, ok := res.Content[0].(*mcp.TextContent)
			if !ok {
				t.Fatalf("CallTool(%s): Content[0] is %T, want *mcp.TextContent", c.tool, res.Content[0])
			}
			if tc.Text != want {
				t.Fatalf("CallTool(%s): Content text = %q, want %q — a raw, unsanitized error leaked to the caller", c.tool, tc.Text, want)
			}
		})
	}
}

// TestListDatabasesSchemaHasNoDatabaseProperty pins list_databases'
// advertised input schema: it must not have a "database" property. Round 1
// added listDatabasesArg (an empty struct) specifically so the schema
// wouldn't advertise a parameter the handler silently ignores; nothing
// asserted on the schema itself, so a regression back to dbArg (which does
// have a "database" property) went undetected. Checking for the
// property's absence, rather than the exact schema JSON blob, keeps this
// test from breaking on unrelated/cosmetic schema changes (e.g. an SDK
// version adding new schema keywords).
func TestListDatabasesSchemaHasNoDatabaseProperty(t *testing.T) {
	cs := connectedClient(t)
	ctx := context.Background()

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}

	var schemaRaw any
	found := false
	for _, tool := range res.Tools {
		if tool.Name == "list_databases" {
			found = true
			schemaRaw = tool.InputSchema
			break
		}
	}
	if !found {
		t.Fatal("list_databases tool not found in ListTools result")
	}

	raw, err := json.Marshal(schemaRaw)
	if err != nil {
		t.Fatalf("marshal list_databases InputSchema: %v", err)
	}
	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("unmarshal list_databases InputSchema: %v", err)
	}

	// Canary: without this, a nil or empty InputSchema would also satisfy
	// "advertises no database property" and the assertion below would be
	// skipped entirely on the green path.
	if schema["type"] != "object" {
		t.Fatalf("list_databases InputSchema.type is %v, want \"object\": %s", schema["type"], raw)
	}

	if props, ok := schema["properties"]; ok {
		propsMap, ok := props.(map[string]any)
		if !ok {
			t.Fatalf("list_databases InputSchema.properties is %T, want an object: %v", props, schema)
		}
		if _, has := propsMap["database"]; has {
			t.Fatalf("list_databases InputSchema advertises a %q property, want none: %s", "database", raw)
		}
	}
	// Absence of a "properties" key entirely also satisfies "no database
	// property advertised".
}

// The mutate tool is registered and advertises the two params it takes.
// Kept alongside the other tool-surface tests because a tool that is
// registered but not advertised is unreachable to a client.
//
// This file has no listToolNames helper; the existing tool-listing
// coverage (TestListDatabasesSchemaHasNoDatabaseProperty above) enumerates
// registered tools via a real client/server round trip — connectedClient
// plus ListTools — rather than inspecting newServer's internals directly,
// so that's what this test does too.
func TestMutateToolIsRegistered(t *testing.T) {
	cs := connectedClient(t)
	ctx := context.Background()

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}

	var names []string
	for _, tool := range res.Tools {
		names = append(names, tool.Name)
	}

	want := []string{"list_databases", "list_tables", "describe_table", "list_columns", "query", "mutate", "read_table", "classify_statement", "render_update"}
	for _, w := range want {
		if !slices.Contains(names, w) {
			t.Errorf("tool %q must be registered; got %v", w, names)
		}
	}
}

// TestClassifyStatementOpensNoConnection pins the property that makes
// asking-before-running cheap enough to do on every keystroke of Return:
// the tool resolves the driver kind out of configuration and stops. The
// fixture's database ref names a Keychain entry that does not exist, so
// any attempt to OPEN the database would fail — and the call still
// succeeds, because classify_statement never opens it.
func TestClassifyStatementOpensNoConnection(t *testing.T) {
	setupProject(t, `"staging":{"databases":[{"name":"main","driver":"sqlite","ref":"wakil-test-nonexistent-credential-xyz"}]}`, "staging")

	cs := connectedClient(t)
	ctx := context.Background()

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name:      "classify_statement",
		Arguments: map[string]any{"statement": "UPDATE events SET kind = 'x' WHERE id = 1"},
	})
	if err != nil {
		t.Fatalf("CallTool(classify_statement): %v", err)
	}
	if res.IsError {
		t.Fatalf("classify_statement returned isError=true: %v", res.Content)
	}

	// Round-trip through JSON rather than a type assertion on
	// StructuredContent directly — what a real client sees is the wire
	// form.
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent: %v", err)
	}
	var structured map[string]any
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent: %v\nraw: %s", err, raw)
	}
	if got := structured["kind"]; got != "mutation" {
		t.Fatalf("structuredContent[%q] = %v, want %q\nfull structuredContent: %s", "kind", got, "mutation", raw)
	}
}

// fakeSecurityBinary swaps PATH so SecretGet's `security find-generic-password`
// call resolves to a script that always answers dsn, instead of ever
// touching the real macOS login Keychain. Mirrors
// internal/wakilcore/dbresolve_test.go's helper of the same name;
// duplicated here (rather than shared) because that one is unexported in a
// different package and this file has no fixture of its own that reaches a
// real database connection yet.
func fakeSecurityBinary(t *testing.T, dsn string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "security")
	body := fmt.Sprintf("#!/bin/sh\nprintf '%%s' %q\n", dsn)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write fake security binary: %v", err)
	}
	// **`WAKIL_SECURITY_BINARY`, not PATH** (2e, #201). The product now
	// invokes the Keychain tool by its absolute path, because the ACL on
	// the CLI's own item names `/usr/bin/security` and a bare name
	// resolved off PATH is a different application to that ACL. A
	// PATH-based fake stopped intercepting the moment that landed — and
	// would have pointed this test at the operator's real login keychain
	// while still passing.
	t.Setenv("WAKIL_SECURITY_BINARY", script)
}

// seedSQLiteEvents creates a fresh, file-backed sqlite database seeded with
// an "events" table of exactly three rows: (1,'b'), (2,'a'), (3,'a'). This
// is the same fixture internal/wakilcore/sqlconn_test.go's openTestSQLite
// uses (see its comment): the "kind" column alone puts ids 2 and 3 in the
// same bucket ('a'), so telling them apart takes the SECOND sort term, by
// id descending. Sorted by kind ascending then id descending, the three
// rows come back 3, 2, 1 — and ONLY the second term distinguishes 3 from
// 2, so an implementation that read just the first sort term would still
// produce a different (wrong) order here. Returns the database file's path,
// suitable as a sqlite Connection.URL.
func seedSQLiteEvents(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "events.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite fixture: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`); err != nil {
		t.Fatalf("create events table: %v", err)
	}
	for _, row := range [][2]any{{1, "b"}, {2, "a"}, {3, "a"}} {
		if _, err := db.Exec(`INSERT INTO events VALUES (?, ?)`, row[0], row[1]); err != nil {
			t.Fatalf("seed events row %v: %v", row, err)
		}
	}
	return path
}

// callTool calls a tool over cs, fails the test on a transport error or a
// tool-level error result, and returns the structured result decoded
// through a JSON round trip — the same round trip
// TestClassifyStatementOpensNoConnection above uses, and what a real
// client actually sees rather than a Go-side type assertion on
// StructuredContent.
func callTool(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) map[string]any {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("CallTool(%s): %v", name, err)
	}
	if res.IsError {
		var texts []string
		for _, c := range res.Content {
			if tc, ok := c.(*mcp.TextContent); ok {
				texts = append(texts, tc.Text)
			}
		}
		t.Fatalf("CallTool(%s) returned isError=true: %v", name, texts)
	}
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent for %s: %v", name, err)
	}
	var structured map[string]any
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent for %s: %v\nraw: %s", name, err, raw)
	}
	return structured
}

// idColumn extracts the "id" column's values, in row order, from a
// read_table/query result already decoded by callTool. JSON numbers decode
// as float64, so this converts to int64 rather than asserting the wire
// type directly.
func idColumn(t *testing.T, result map[string]any) []int64 {
	t.Helper()
	colsRaw, ok := result["columns"].([]any)
	if !ok {
		t.Fatalf("result[\"columns\"] is %T, want []any: %v", result["columns"], result)
	}
	idx := -1
	for i, c := range colsRaw {
		if s, ok := c.(string); ok && s == "id" {
			idx = i
			break
		}
	}
	if idx == -1 {
		t.Fatalf("result has no %q column: %v", "id", colsRaw)
	}
	rowsRaw, ok := result["rows"].([]any)
	if !ok {
		t.Fatalf("result[\"rows\"] is %T, want []any: %v", result["rows"], result)
	}
	out := make([]int64, 0, len(rowsRaw))
	for _, r := range rowsRaw {
		row, ok := r.([]any)
		if !ok || idx >= len(row) {
			t.Fatalf("row %v does not have an id at index %d", r, idx)
		}
		n, ok := row[idx].(float64)
		if !ok {
			t.Fatalf("id value %v is %T, want a JSON number", row[idx], row[idx])
		}
		out = append(out, int64(n))
	}
	return out
}

// setupSQLiteEventsProject wires an active project/environment with a
// single sqlite database named "events-db" whose credential (via the fake
// security binary) resolves to a real, file-backed sqlite database seeded
// by seedSQLiteEvents. This is what lets a test drive read_table/query all
// the way through openPicked -> OpenDatabase -> a real sqlite connection,
// rather than stopping at the resolution layer as every other test in
// this file deliberately does.
func setupSQLiteEventsProject(t *testing.T) {
	t.Helper()
	path := seedSQLiteEvents(t)
	fakeSecurityBinary(t, path)
	setupProject(t, `"staging":{"databases":[{"name":"events-db","driver":"sqlite","ref":"events-db-ref"}]}`, "staging")
}

// The wire carries every term, in order. Two terms is the case that could
// not be expressed before and the only one that proves the array is read
// as an array rather than as its first element.
func TestReadTableAcceptsMultipleSortTerms(t *testing.T) {
	setupSQLiteEventsProject(t)
	client := connectedClient(t)
	result := callTool(t, client, "read_table", map[string]any{
		"name": "events",
		"sort": []map[string]any{
			{"column": "kind", "descending": false},
			{"column": "id", "descending": true},
		},
	})
	ids := idColumn(t, result)
	want := []int64{3, 2, 1}
	if !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
}

// setupSQLiteEventsWritableProject is setupSQLiteEventsProject's
// render_update/mutate-path sibling: same seeded "events" table
// (seedSQLiteEvents — rows (1,'b'), (2,'a'), (3,'a')), but the database
// entry also carries a writeRef, so openPickedWritable can succeed against
// it. fakeSecurityBinary answers every Keychain lookup with the same
// sqlite file path regardless of which ref name is asked for, so ref and
// writeRef resolve to the same on-disk database. Returns the file path so
// a test can open a second, independent connection afterwards and check
// that a row was (or was not) actually changed.
func setupSQLiteEventsWritableProject(t *testing.T) string {
	t.Helper()
	path := seedSQLiteEvents(t)
	fakeSecurityBinary(t, path)
	setupProject(t, `"staging":{"databases":[{"name":"events-db","driver":"sqlite","ref":"events-db-ref","writeRef":"events-db-write-ref"}]}`, "staging")
	return path
}

// TestRenderUpdateComposesAndRunsNothing is render_update's core contract
// test, per task-7-brief.md: it must compose the exact statement text,
// change nothing in the database (mutate is the only tool that runs
// anything), and refuse a bad value with the gate's own sentence rather
// than a composed statement.
func TestRenderUpdateComposesAndRunsNothing(t *testing.T) {
	path := setupSQLiteEventsWritableProject(t)
	cs := connectedClient(t)

	out := callTool(t, cs, "render_update", map[string]any{
		"table":      "events",
		"rowKey":     `"id" = '1'`,
		"column":     "kind",
		"columnType": "TEXT",
		"value":      "c",
	})
	got := out["statement"]
	want := `UPDATE "events" SET "kind" = 'c' WHERE "id" = '1'`
	if got != want {
		t.Fatalf("statement = %v, want %s", got, want)
	}

	// IT RAN NOTHING. This is the whole contract: the statement goes to
	// mutate, which is where the gate, the production block and the human
	// confirmation are. Opened as a second, independent connection to the
	// same file, rather than reusing anything render_update touched, so
	// this really observes what is on disk.
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite fixture for verification: %v", err)
	}
	defer db.Close()
	var kind string
	if err := db.QueryRow(`SELECT kind FROM events WHERE id = 1`).Scan(&kind); err != nil {
		t.Fatal(err)
	}
	if kind != "b" {
		t.Fatalf("render_update changed the row: kind = %q, want unchanged %q", kind, "b")
	}

	// A refusal comes back as a tool error carrying the gate's own
	// sentence, not as a composed statement.
	ctx := context.Background()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "render_update",
		Arguments: map[string]any{
			"table": "events", "rowKey": `"id" = '1'`, "column": "id",
			"columnType": "INTEGER", "value": "abc",
		},
	})
	if err != nil {
		t.Fatalf("CallTool(render_update): %v", err)
	}
	if !res.IsError {
		t.Fatal("a non-numeric value for an INTEGER column should be refused")
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] is %T, want *mcp.TextContent", res.Content[0])
	}
	wantErr := `"abc" is not a number, and id is a INTEGER column`
	if tc.Text != wantErr {
		t.Fatalf("error text = %q, want %q", tc.Text, wantErr)
	}
}

// TestRenderUpdateRequiresWriteRef pins that render_update opens the
// WRITABLE connection, not the read one: a database configured with only
// a "ref" (no "writeRef") must fail exactly the way mutate does — with
// OpenDatabaseWritable's own sentence — and must do so without composing
// any statement. setupSQLiteEventsProject (no writeRef) is reused
// unchanged rather than building a second fixture.
func TestRenderUpdateRequiresWriteRef(t *testing.T) {
	setupSQLiteEventsProject(t)
	cs := connectedClient(t)
	ctx := context.Background()

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "render_update",
		Arguments: map[string]any{
			"table": "events", "rowKey": `"id" = '1'`, "column": "kind",
			"columnType": "TEXT", "value": "c",
		},
	})
	if err != nil {
		t.Fatalf("CallTool(render_update): %v", err)
	}
	if !res.IsError {
		t.Fatal("render_update against a database with no writeRef should be refused")
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] is %T, want *mcp.TextContent", res.Content[0])
	}
	wantErr := `database "events-db" is not configured for writing: add a "writeRef" naming a Keychain entry whose credential the server has granted write permission to`
	if tc.Text != wantErr {
		t.Fatalf("error text = %q, want %q", tc.Text, wantErr)
	}
}

// TestRenderUpdateMongoAnswersHonestly is the Mongo half of "Mongo must
// answer honestly rather than panic."
//
// It does NOT need a live Mongo server, and deliberately is not gated
// behind make test-live: mongoDriver.ConnectWritable (driver_mongo.go)
// refuses unconditionally, before it ever opens a socket or constructs a
// *mongoConn — "mongo mutation is not implemented yet (Wakil writes to
// SQL databases only)" — so openPickedWritable itself fails here and
// render_update's own interface assertion is never reached. That
// assertion (conn.(interface{ RenderUpdate(...) (string, error) })) is
// therefore, on this tree, defense-in-depth rather than the live guard:
// grep confirms mongoConn has no RenderUpdate method, so if a future
// ConnectWritable ever succeeded and handed back a real *mongoConn, the
// assertion would still correctly fail closed with "this database cannot
// compose an update" instead of panicking. What this test actually pins
// is the outer, currently-reachable half of the same promise: a
// Mongo-backed database answers render_update with one plain sentence,
// never a panic, at every step of the chain.
func TestRenderUpdateMongoAnswersHonestly(t *testing.T) {
	fakeSecurityBinary(t, "mongodb://127.0.0.1:1/testdb")
	setupProject(t, `"staging":{"databases":[{"name":"events-db","driver":"mongo","ref":"events-db-ref","writeRef":"events-db-write-ref"}]}`, "staging")
	cs := connectedClient(t)
	ctx := context.Background()

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "render_update",
		Arguments: map[string]any{
			"table": "events", "rowKey": `{"_id":1}`, "column": "kind",
			"columnType": "", "value": "c",
		},
	})
	if err != nil {
		t.Fatalf("CallTool(render_update): %v", err)
	}
	if !res.IsError {
		t.Fatal("render_update against a mongo database should be refused, not composed")
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] is %T, want *mcp.TextContent", res.Content[0])
	}
	wantErr := "mongo mutation is not implemented yet (Wakil writes to SQL databases only)"
	if tc.Text != wantErr {
		t.Fatalf("error text = %q, want %q", tc.Text, wantErr)
	}
}

func TestListColumnsReturnsEveryTablesColumns(t *testing.T) {
	setupSQLiteEventsProject(t) // events(id, kind)
	cs := connectedClient(t)
	result := callTool(t, cs, "list_columns", map[string]any{})
	tables, ok := result["tables"].([]any)
	if !ok || len(tables) != 1 {
		t.Fatalf("tables = %#v, want one table", result["tables"])
	}
	first := tables[0].(map[string]any)
	if first["table"] != "events" {
		t.Fatalf("table = %v, want events", first["table"])
	}
	if !reflect.DeepEqual(first["columns"], []any{"id", "kind"}) {
		t.Fatalf("columns = %v, want [id kind]", first["columns"])
	}
}
