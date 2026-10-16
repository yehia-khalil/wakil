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
// environments and scopes JSON fragments, registers it as the active
// project, and (if envName is non-empty) selects envName as the active
// environment. Mirrors cmd/wakil-db/main_test.go's setupProject.
func setupProject(t *testing.T, scopesJSON, environmentsJSON, envName string) {
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
	body := `{"name":"proj","org":"initech","roots":[{"path":"."}],"scopes":{` + scopesJSON + `},"environments":{` + environmentsJSON + `}}`
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

// fakeSecurityBinary writes a fake `security` executable to a fresh temp
// dir and points PATH at it, so SecretGet resolves to a script under the
// test's control instead of the real macOS Keychain. See
// internal/wakilcore/secrets_test.go and dbresolve_test.go for the same
// PATH-substitution technique this reuses.
func fakeSecurityBinary(t *testing.T, value string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "security")
	body := "#!/bin/sh\nprintf '%s' " + shQuote(value) + "\n"
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

func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
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

	client := mcp.NewClient(&mcp.Implementation{Name: "wakil-pm-test-client", Version: "0.0.0"}, nil)
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

// TestMyIssuesAndSearchIssuesNoActiveProject pins that both project-scoped
// tools fail with Resolve's exact "no active project" sentence when no
// project is active — before ever touching Jira credentials.
func TestMyIssuesAndSearchIssuesNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	t.Setenv("WAKIL_JIRA_BASE", "")

	cs := connectedClient(t)
	const want = "no active project — run set_project first"
	callToolExpectError(t, cs, "my_issues", map[string]any{}, want)
	callToolExpectError(t, cs, "search_issues", map[string]any{}, want)
}

// TestGetIssueNoJiraBase pins that once the active project resolves
// successfully (a Jira pm scope configured), get_issue's next failure is
// NewJiraFromEnv's no-Jira-site-configured message — project resolution
// and Jira-env resolution run in that order. get_issue now DOES depend
// on an active project (ruling Important-3: it enforces project scope on
// the key), unlike before this fix round — see
// TestGetIssueRequiresActiveProject for that half.
//
// The expected text names the org and the fix command rather than
// WAKIL_JIRA_BASE: NewJiraFromEnv now reads the base URL from org.json
// (setupProject registers org "initech" but never writes an org.json), with
// WAKIL_JIRA_BASE surviving only as an override — see
// internal/wakilcore/jira.go's NewJiraFromEnv.
func TestGetIssueNoJiraBase(t *testing.T) {
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`, `"staging":{"databases":[]}`, "staging")
	t.Setenv("WAKIL_JIRA_BASE", "")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "get_issue", map[string]any{"key": "RAF-1"}, "wakil org set initech --jira-base")
}

// TestGetIssueRequiresActiveProject pins the ruling Important-3 behavior
// change: get_issue now enforces project scope (a key's project prefix
// must match the active project's Jira key), so — unlike before this fix
// round — it DOES depend on there being an active project with a Jira
// scope configured, and that dependency must fail first, before Jira
// credentials are ever touched.
func TestGetIssueRequiresActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	t.Setenv("WAKIL_JIRA_BASE", "")

	cs := connectedClient(t)
	const want = "no active project — run set_project first"
	callToolExpectError(t, cs, "get_issue", map[string]any{"key": "RAF-1"}, want)
}

// TestNoJiraScopeConfigured pins projectKey()'s own guard: an active
// project with no scopes.pm configured must fail with a distinct message
// from "no active project", so an operator can tell "wrong project" apart
// from "right project, missing Jira config".
func TestNoJiraScopeConfigured(t *testing.T) {
	setupProject(t, ``, `"staging":{"databases":[]}`, "staging")
	t.Setenv("WAKIL_JIRA_BASE", "")

	cs := connectedClient(t)
	const want = "this project has no Jira scope configured"
	callToolExpectError(t, cs, "my_issues", map[string]any{}, want)
	callToolExpectError(t, cs, "search_issues", map[string]any{"jql": ""}, want)
	callToolExpectError(t, cs, "get_issue", map[string]any{"key": "RAF-1"}, want)
}

// TestSanitizesNonUserError pins the same defect class task 13 fixed for
// wakil-db: ReadActive returns a raw *json.SyntaxError on malformed
// active.json, and that error must reach the caller wrapped by
// mcpx.ToolErr's "an internal error occurred" sentence, never as the raw
// Go error text, and never via the forbidden
// `return nil, <zero>, err` shape (which the SDK would otherwise report
// through a *different* code path that also happens to leak the same raw
// text — asserting the exact "wakil-pm: an internal error occurred: "
// prefix, which only ToolErr produces, is what actually distinguishes the
// two shapes here).
func TestSanitizesNonUserError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	t.Setenv("WAKIL_JIRA_BASE", "")

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
	want := "wakil-pm: an internal error occurred: " + rawErr.Error()

	cs := connectedClient(t)
	callToolExpectError(t, cs, "my_issues", map[string]any{}, want)
	callToolExpectError(t, cs, "search_issues", map[string]any{"jql": ""}, want)
	callToolExpectError(t, cs, "get_issue", map[string]any{"key": "RAF-1"}, want)
}

// TestSearchIssuesRejectsInjectionThroughToolLayer exercises the full
// stack — project scope resolution, Jira credential resolution via a fake
// Keychain, then JiraClient.SearchIssues's own validation — and confirms
// the scope-escape payload never reaches the network: BaseURL is
// deliberately unroutable, so a stray HTTP call would fail loudly rather
// than silently succeeding, and the assertion is on the specific
// "parenthes" wording SearchIssues' validator produces, not merely on an
// error existing.
func TestSearchIssuesRejectsInjectionThroughToolLayer(t *testing.T) {
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`, `"staging":{"databases":[]}`, "staging")
	t.Setenv("WAKIL_JIRA_BASE", "https://127.0.0.1:1")
	fakeSecurityBinary(t, "person@example.com:tok123")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "search_issues", map[string]any{"jql": "x) OR (1=1"}, "parenthes")
}

// TestGetIssueRejectsInvalidKeyThroughToolLayer confirms GetIssue's own
// key-format validation (issue key regex) is reached and enforced through
// the full MCP tool-call stack, again without ever reaching the network.
// Since ruling Important-3, get_issue resolves the active project before
// validating the key, so a project with a Jira pm scope must be set up
// for this test to reach GetIssue at all.
func TestGetIssueRejectsInvalidKeyThroughToolLayer(t *testing.T) {
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`, `"staging":{"databases":[]}`, "staging")
	t.Setenv("WAKIL_JIRA_BASE", "https://127.0.0.1:1")
	fakeSecurityBinary(t, "person@example.com:tok123")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "get_issue", map[string]any{"key": "not-a-key"}, "invalid issue key")
}

// TestGetIssueRejectsCrossProjectKeyThroughToolLayer confirms GetIssue's
// ruling Important-3 project-scope check (not just its key-format check)
// is reached and enforced through the full MCP tool-call stack, without
// ever reaching the network — "OTHER-1" is a validly formatted issue key
// but belongs to a different project than the active one (RAF).
func TestGetIssueRejectsCrossProjectKeyThroughToolLayer(t *testing.T) {
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`, `"staging":{"databases":[]}`, "staging")
	t.Setenv("WAKIL_JIRA_BASE", "https://127.0.0.1:1")
	fakeSecurityBinary(t, "person@example.com:tok123")

	cs := connectedClient(t)
	callToolExpectError(t, cs, "get_issue", map[string]any{"key": "OTHER-1"}, "not in the active project")
}

// TestGetIssueDescriptionDisclosesMissingComments pins the recorded
// deviation from spec §4.2 at the place it actually has consequences.
//
// wakilcore.GetIssue returns no comments (see its doc comment for why the
// gap was left rather than closed blind). A tool description is not
// documentation for a human reviewer — it is the only thing an LLM reads
// before deciding what a result means. Without this sentence a model sees
// an Issue with no comment field, concludes the issue has no discussion,
// and tells the user so with full confidence. That is a wrong answer
// produced by a correct program, and the description is the only place it
// can be prevented.
//
// The assertion goes through ListTools rather than reading the literal in
// main.go, so it pins what a CLIENT is actually told.
func TestGetIssueDescriptionDisclosesMissingComments(t *testing.T) {
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	defer ss.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "pm-description-test", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	defer cs.Close()

	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	var desc string
	found := false
	for _, tool := range tools.Tools {
		if tool.Name == "get_issue" {
			desc, found = tool.Description, true
		}
	}
	if !found {
		t.Fatal("wakil-pm advertises no get_issue tool")
	}
	// Both halves matter and neither implies the other: the first states
	// the fact, the second forbids the inference a model would otherwise
	// draw from it.
	if !strings.Contains(desc, "COMMENTS ARE NOT INCLUDED") {
		t.Errorf("get_issue description does not state that comments are absent: %q", desc)
	}
	if !strings.Contains(desc, "no discussion") {
		t.Errorf("get_issue description does not warn against concluding an issue has no discussion: %q", desc)
	}
}
