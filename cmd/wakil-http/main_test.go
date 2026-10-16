package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// setupProject writes a minimal project fixture with the given
// environments JSON fragment, registers it as the active project, and
// (if envName is non-empty) selects envName as the active environment.
// Mirrors cmd/wakil-pm/main_test.go's and cmd/wakil-db/main_test.go's
// setupProject.
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

	client := mcp.NewClient(&mcp.Implementation{Name: "wakil-http-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

func callToolExpectError(t *testing.T, cs *mcp.ClientSession, tool string, args map[string]any, want string) {
	t.Helper()
	ctx := context.Background()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("CallTool(%s): %v", tool, err)
	}
	if !res.IsError {
		t.Fatalf("CallTool(%s): expected IsError=true, got result %+v", tool, res)
	}
	if len(res.Content) == 0 {
		t.Fatalf("CallTool(%s): expected non-empty Content", tool)
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("CallTool(%s): Content[0] is %T, want *mcp.TextContent", tool, res.Content[0])
	}
	if !strings.Contains(tc.Text, want) {
		t.Fatalf("CallTool(%s): Content text = %q, want a message containing %q", tool, tc.Text, want)
	}
}

func TestNewServerBuilds(t *testing.T) {
	s := newServer()
	if s == nil {
		t.Fatal("newServer returned nil")
	}
}

// TestRequestNoActiveProject pins that the tool fails with Resolve's
// exact "no active project" sentence when no project is active — before
// ever looking at env.API.
func TestRequestNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"}, "no active project — run set_project first")
}

// TestRequestNoActiveEnvironment pins ResolveEnvironment's "no active
// environment" sentence when a project is active but no environment has
// been selected.
func TestRequestNoActiveEnvironment(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`, "")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"}, "no active environment")
}

// TestRequestNoBaseURLConfigured pins the tool's own guard: an active
// environment declaring no API entry must fail with a distinct, specific
// message, not a nil-pointer panic or a generic Go error.
//
// **The wording changed with #183 and the guard moved.** It used to read
// "this environment has no API baseUrl configured", tested on the handler's
// own nil check. `api` is an array now, so the same condition is "no
// entries" and PickAPI owns the sentence — the same resolver, and the same
// refusal vocabulary, PickDatabase has always used. The claim being pinned
// is unchanged: a specific message rather than a panic.
func TestRequestNoBaseURLConfigured(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"}, "no api configured for this environment")
}

// An environment holding SEVERAL entries refuses an omitted name rather
// than guessing, because guessing sends one backend's credential to
// another backend's host (#183).
func TestRequestRefusesAnOmittedNameWhenSeveralEntriesExist(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[`+
		`{"name":"api","baseUrl":"https://127.0.0.1:1"},`+
		`{"name":"billing","baseUrl":"https://127.0.0.1:2"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"},
		"name one of them")
}

// An entry name the active environment does not hold fails loudly — never
// a silent fallback to a different backend.
func TestRequestRefusesAnUnknownEntryRatherThanFallingBack(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request",
		map[string]any{"method": "GET", "path": "/x", "api": "billing"},
		"no api entry named billing")
}

// TestRequestRejectsNonHTTPSBaseURL pins controller ruling 8 wired all
// the way through the tool: an http:// (non-https) baseUrl must be
// rejected before any network call, via NormalizeHTTPBase.
func TestRequestRejectsNonHTTPSBaseURL(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"http://insecure.example"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"}, "must be an absolute https URL")
}

// TestRequestRejectsUserinfoInBaseURL pins the other half of ruling 8: a
// baseUrl carrying userinfo is a second credential channel entirely
// outside the Keychain, and must be rejected with the credential
// redacted from the echoed value (url.URL.Redacted()'s job), not merely
// rejected silently.
func TestRequestRejectsUserinfoInBaseURL(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://user:hunter2@example.com"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"}, "must not contain credentials")
	// And the password itself must never appear verbatim in the message.
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "request", Arguments: map[string]any{"method": "GET", "path": "/x"}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] is %T", res.Content[0])
	}
	if strings.Contains(tc.Text, "hunter2") {
		t.Fatalf("password leaked into error message: %q", tc.Text)
	}
}

// TestRequestRejectsDotDotPathThroughToolLayer exercises the full stack
// (environment resolution, base validation, then DoRequest's own guard)
// and confirms a ".." path segment is rejected before any network call:
// BaseURL points at an address with no listener, so a stray dial would
// fail with a distinct connection-refused-shaped message rather than
// this rejection's specific wording.
func TestRequestRejectsDotDotPathThroughToolLayer(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "../etc/passwd"}, "\"..\"")
}

// TestRequestRejectsCallerAuthorizationHeaderThroughToolLayer confirms
// controller ruling 6 is reachable end to end through the tool, not only
// at the wakilcore.DoRequest unit level.
func TestRequestRejectsCallerAuthorizationHeaderThroughToolLayer(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x", "headers": map[string]any{"Authorization": "Bearer forged"}}, "Authorization")
}

// TestRequestRejectsWriteVerbThroughToolLayer confirms the read-only
// gate is reached before any network call, through the full tool layer.
func TestRequestRejectsWriteVerbThroughToolLayer(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "POST", "path": "/x"}, "read-only")
}

// TestRequestSanitizesNonUserError pins the same defect class fixed for
// wakil-db and wakil-pm: ReadActive returns a raw *json.SyntaxError on
// malformed per-org active file, and that error must reach the caller wrapped by
// mcpx.ToolErr's "an internal error occurred" sentence, never as the raw
// Go error text.
func TestRequestSanitizesNonUserError(t *testing.T) {
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
	malformed := []byte(`{"project": `)
	orgDir, err := wakilcore.OrgDir()
	if err != nil {
		t.Fatalf("OrgDir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(orgDir, "active.json"), malformed, 0o644); err != nil {
		t.Fatalf("write malformed active.json: %v", err)
	}

	var v wakilcore.ActiveContext
	rawErr := json.Unmarshal(malformed, &v)
	if rawErr == nil {
		t.Fatal("test fixture bug: malformed JSON did not actually fail to unmarshal")
	}
	if _, ok := rawErr.(*json.SyntaxError); !ok {
		t.Fatalf("test fixture bug: expected a *json.SyntaxError, got %T: %v", rawErr, rawErr)
	}
	want := "wakil-http: an internal error occurred: " + rawErr.Error()

	cs := connectedClient(t)
	callToolExpectError(t, cs, "request", map[string]any{"method": "GET", "path": "/x"}, want)
}

// list_apis at the tool layer — that it returns the ACTIVE environment's
// entries, which the schema test cannot see. list_databases has several
// of these and list_apis mirrors it.
func TestListApisReturnsTheActiveEnvironmentsEntries(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[`+
		`{"name":"api","baseUrl":"https://one.example"},`+
		`{"name":"billing","baseUrl":"https://two.example","authRef":"wakil:initech:billing"}]}`, "staging")

	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "list_apis", Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("CallTool(list_apis): %v", err)
	}
	if res.IsError {
		t.Fatalf("list_apis errored: %+v", res.Content)
	}
	b, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := string(b)
	for _, want := range []string{
		`"name":"api"`, `"baseUrl":"https://one.example"`, `"authenticated":false`,
		`"name":"billing"`, `"baseUrl":"https://two.example"`, `"authenticated":true`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("list_apis missing %s in %s", want, got)
		}
	}
	// The ref is the whole reason this type is separate from ApiConfig.
	if strings.Contains(got, "wakil:initech:billing") || strings.Contains(got, "authRef") {
		t.Errorf("list_apis leaked the Keychain ref: %s", got)
	}
}

// An environment declaring no entries answers an empty array, not null —
// mcpx's rule, and the difference between "none" and "could not look".
func TestListApisAnswersAnEmptyArrayForAnEnvironmentWithNoEntries(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`, "staging")

	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "list_apis", Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("CallTool(list_apis): %v", err)
	}
	b, _ := json.Marshal(res.StructuredContent)
	if string(b) != `{"apis":[]}` {
		t.Errorf("got %s", b)
	}
}

func TestParseCurlTool(t *testing.T) {
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "parse_curl", Arguments: map[string]any{"text": `curl -X POST https://a.example/x -H 'Authorization: Bearer s3cr3t' -d '{}'`}})
	if err != nil || res.IsError {
		t.Fatalf("parse_curl: %v %+v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if strings.Contains(string(raw), "s3cr3t") || !strings.Contains(string(raw), `"Authorization"`) {
		t.Fatalf("structured: %s", raw)
	}
}

func TestLocateAPIURLTool(t *testing.T) {
	setupProject(t, `"staging":{"api":[{"name":"billing","baseUrl":"https://billing.example.com"}]},`+
		`"qa":{"api":[{"name":"catalog","baseUrl":"https://catalog-qa.example.com"}]}`, "staging")
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "locate_api_url", Arguments: map[string]any{"url": "https://catalog-qa.example.com/x"}})
	if err != nil || res.IsError {
		t.Fatalf("locate_api_url: %v %+v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(raw), `"environment":"qa"`) || !strings.Contains(string(raw), `"entry":"catalog"`) {
		t.Fatalf("structured: %s", raw)
	}
}
