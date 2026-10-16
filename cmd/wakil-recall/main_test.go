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

// setupProject writes a minimal project fixture with the given scopes
// JSON fragment, registers it as the active project, and selects
// "staging" as the active environment. Mirrors cmd/wakil-pm and
// cmd/wakil-db's setupProject; recall has no per-environment
// configuration of its own, so the environment exists only to make the
// fixture a valid project.
func setupProject(t *testing.T, scopesJSON string) {
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
	body := `{"name":"proj","org":"initech","roots":[{"path":"."}],"scopes":{` + scopesJSON + `},"environments":{"staging":{"databases":[]}}}`
	if err := os.WriteFile(pp, []byte(body), 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}

	if err := wakilcore.SaveRegistry("initech", map[string]wakilcore.ProjectEntry{"proj": {Path: pp}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}
	if err := wakilcore.SetProjectChecked("proj"); err != nil {
		t.Fatalf("SetProjectChecked: %v", err)
	}
	active, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	active.Environment = "staging"
	if err := wakilcore.WriteActive(active); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}
}

// noKeychain points PATH at an empty directory so wakilcore.SecretGet
// cannot find the `security` binary and fails loudly instead of reading
// the developer's real login keychain.
//
// No test here is SUPPOSED to reach SecretGet — every one either stops
// before Jira is consulted at all, or fails inside NewJiraFromEnv on the
// base URL first, whether because WAKIL_JIRA_BASE is unset or because it
// is set to something normalizeJiraBase rejects (see
// TestRecallDoesNotLeakACredentialFromTheBaseURL). secrets.go's SecretGet
// is only called after that check. This is the backstop that turns a
// regression in that ordering into a visibly different error message
// rather than a silent prompt against the real keychain. See
// cmd/wakil-pm/main_test.go's fakeSecurityBinary for the same
// PATH-substitution technique used to supply a fake credential.
func noKeychain(t *testing.T) {
	t.Helper()
	t.Setenv("WAKIL_SECURITY_BINARY", filepath.Join(t.TempDir(), "security"))
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

	client := mcp.NewClient(&mcp.Implementation{Name: "wakil-recall-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

func callRecall(t *testing.T, cs *mcp.ClientSession, query string) *mcp.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "recall",
		Arguments: map[string]any{"query": query},
	})
	if err != nil {
		t.Fatalf("CallTool(recall): %v", err)
	}
	return res
}

// errorText asserts res is a tool ERROR and returns its single text
// block. Asserting IsError before reading Content is what stops a
// success result from being mistaken for an error whose message merely
// happened to contain the wanted substring.
func errorText(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	if !res.IsError {
		t.Fatalf("expected IsError=true, got result %+v", res)
	}
	if len(res.Content) == 0 {
		t.Fatalf("expected non-empty Content, got %+v", res)
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] is %T, want *mcp.TextContent", res.Content[0])
	}
	return tc.Text
}

// successJSON asserts res is a tool SUCCESS and returns the JSON text the
// SDK produced from the handler's typed RecallOutput. That text is the
// literal wire form of the result, which is what the `[]`-not-`null`
// assertions below need — reading the decoded StructuredContent instead
// would go through a round trip that could paper over the difference.
func successJSON(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	if res.IsError {
		t.Fatalf("expected a successful result, got IsError with %+v", res.Content)
	}
	if len(res.Content) == 0 {
		t.Fatalf("expected non-empty Content, got %+v", res)
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] is %T, want *mcp.TextContent", res.Content[0])
	}
	return tc.Text
}

func decodeOutput(t *testing.T, raw string) wakilcore.RecallOutput {
	t.Helper()
	var out wakilcore.RecallOutput
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("decode RecallOutput from %s: %v", raw, err)
	}
	return out
}

func TestNewServerBuilds(t *testing.T) {
	// Smoke test: a bad input/output schema makes mcp.AddTool panic (see
	// cmd/wakil-db/main_test.go's TestNewServerBuilds for the SDK detail
	// behind this), and RecallOutput's map-of-slices shape is the first
	// non-flat output type in this repo.
	if s := newServer(); s == nil {
		t.Fatal("newServer returned nil")
	}
}

// TestRecallNoActiveProject pins that with no active project the whole
// call fails with Resolve's exact sentence, as a tool error — before any
// source is consulted.
func TestRecallNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	t.Setenv("WAKIL_JIRA_BASE", "")
	noKeychain(t)

	got := errorText(t, callRecall(t, connectedClient(t), "date picker"))
	if want := "no active project — run set_project first"; got != want {
		t.Fatalf("Content text = %q, want %q", got, want)
	}
}

// TestRecallEmptyQueryIsAToolError pins that a query the core refuses
// (ruling 4) reaches the caller as a tool error with the actionable
// sentence — not as an empty success that reads like "nothing matched".
func TestRecallEmptyQueryIsAToolError(t *testing.T) {
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`)
	t.Setenv("WAKIL_JIRA_BASE", "")
	noKeychain(t)

	for _, q := range []string{"", "   "} {
		got := errorText(t, callRecall(t, connectedClient(t), q))
		if want := "recall needs something to search for"; got != want {
			t.Fatalf("query %q: Content text = %q, want %q", q, got, want)
		}
	}
}

// TestRecallUnconfiguredJiraIsVisible is the whole point of this server's
// output shape, exercised end to end through a real MCP round trip: a
// project WITH a Jira scope but no Jira site configured anywhere (no
// WAKIL_JIRA_BASE override, no jiraBase in org.json — setupProject
// registers org "initech" but never writes an org.json) — the most likely
// real-world state, per docs/wakil/operator-todo.md §2 — must come back
// as a SUCCESSFUL call whose sources array says, in NewJiraFromEnv's own
// words, that Jira did not answer. The empty group alone would read to
// an LLM as "Jira has no matching issues".
func TestRecallUnconfiguredJiraIsVisible(t *testing.T) {
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`)
	t.Setenv("WAKIL_JIRA_BASE", "")
	noKeychain(t)

	raw := successJSON(t, callRecall(t, connectedClient(t), "date picker"))
	// The wire form, asserted literally: a failed source's group must be
	// an empty ARRAY. `null` (or an absent group) is indistinguishable
	// from a source that was never bound.
	if !strings.Contains(raw, `"jira":[]`) {
		t.Fatalf("result JSON = %s, want groups.jira to be []", raw)
	}

	out := decodeOutput(t, raw)
	if len(out.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly one entry for the bound-but-unconfigured Jira source", out.Sources)
	}
	got := out.Sources[0]
	if got.Source != "jira" || got.OK {
		t.Fatalf("sources[0] = %+v, want source \"jira\" with ok=false", got)
	}
	if want := `no Jira site configured for org "initech" — set one with: wakil org set initech --jira-base https://<site>.atlassian.net`; got.Message != want {
		t.Fatalf("sources[0].message = %q, want NewJiraFromEnv's own diagnostic %q", got.Message, want)
	}
	if group, ok := out.Groups["jira"]; !ok || group == nil || len(group) != 0 {
		t.Fatalf("groups[\"jira\"] = %+v (present=%v), want an empty non-nil slice", group, ok)
	}
}

// TestRecallNoJiraScopeEmitsNoSource pins the other half of that
// distinction through the tool layer: a project with no Jira scope is not
// broken, so it contributes neither a group nor a status — and, because
// the source is never consulted, never touches the Keychain either.
func TestRecallNoJiraScopeEmitsNoSource(t *testing.T) {
	setupProject(t, ``)
	t.Setenv("WAKIL_JIRA_BASE", "")
	noKeychain(t)

	raw := successJSON(t, callRecall(t, connectedClient(t), "date picker"))
	if want := `{"groups":{},"sources":[]}`; raw != want {
		t.Fatalf("result JSON = %s, want %s — an unbound source must contribute nothing at all, and neither field may be null", raw, want)
	}
}

// TestRecallSanitizesNonUserError pins the handler's return shape on the
// one failure in this suite that is NOT a UserError.
//
// wakilcore.ReadActive returns a raw *json.SyntaxError when
// ~/.wakil/orgs/<org>/active.json is malformed, and Resolve passes it straight
// through to Recall's caller. For a UserError the forbidden
// `return nil, <zero>, err` shape and the required
// `return mcpx.ToolErr(...), <zero>, nil` shape produce byte-identical
// Content, so no other test here can tell them apart; only this one can,
// because ToolErr's "wakil-recall: an internal error occurred: " prefix
// appears in exactly one of the two.
//
// COUPLING (see cmd/wakil-db/main_test.go's longer note): this test's
// pinning power depends on ReadActive NOT wrapping that error in a
// UserError. `want` is built from an independent Unmarshal of the same
// fixture, so such a change makes this test go RED rather than quietly
// pass. Do not repair a red here by updating `want` to the new text —
// re-source it from another genuine non-UserError instead.
func TestRecallSanitizesNonUserError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	t.Setenv("WAKIL_JIRA_BASE", "")
	noKeychain(t)

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
		t.Fatalf("test fixture bug: expected a *json.SyntaxError (a non-UserError), got %T: %v", rawErr, rawErr)
	}
	want := "wakil-recall: an internal error occurred: " + rawErr.Error()

	got := errorText(t, callRecall(t, connectedClient(t), "date picker"))
	if got != want {
		t.Fatalf("Content text = %q, want %q — a raw, unsanitized error leaked to the caller", got, want)
	}
}

// TestRecallDoesNotLeakACredentialFromTheBaseURL carries the
// normalizeJiraBase fix all the way to the MCP wire.
//
// wakilcore has two tests for this already —
// TestNormalizeJiraBaseNeverEchoesACredential on the sentence, and
// TestRecallDoesNotLeakACredentialFromWAKIL_JIRA_BASE on the RecallOutput
// value — but neither goes through a real tool call, and the wire form is
// the whole reason this leak mattered. SourceStatus.Message is a field of
// a SUCCESSFUL result, not an error, so it is not IsError text an operator
// skims: it is JSON this server's own tool description instructs the model
// to read, and it lands verbatim in an LLM transcript.
//
// The base URL is "https://<token>@host" — no colon, so the
// url.URL.Redacted() this once used masked nothing and echoed the
// operator's Atlassian API token back in full. A 192-character token is
// used rather than a toy one per standing lesson 4.
func TestRecallDoesNotLeakACredentialFromTheBaseURL(t *testing.T) {
	// 192 characters, the scale of a real Atlassian API token.
	tok := strings.Repeat("A1b2C3d4", 24)
	setupProject(t, `"pm":{"provider":"jira","projectKey":"RAF"}`)
	t.Setenv("WAKIL_JIRA_BASE", "https://"+tok+"@acme.atlassian.net")
	// normalizeJiraBase rejects that base before SecretGet is reached,
	// so this is a backstop rather than a load-bearing stub — see
	// noKeychain.
	noKeychain(t)

	// A SUCCESSFUL call, which is the point: the diagnostic rides in the
	// result body, so errorText would not even see it.
	raw := successJSON(t, callRecall(t, connectedClient(t), "date picker"))

	out := decodeOutput(t, raw)
	if len(out.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly one entry", out.Sources)
	}
	// Exact sentence first: an absence check alone would pass on an
	// empty message, or if the origin that tells an operator WHICH base
	// URL is wrong were dropped along with the token.
	const want = "WAKIL_JIRA_BASE must not contain credentials — store the Jira token in the Keychain, not the base URL, got https://acme.atlassian.net"
	if got := out.Sources[0].Message; got != want {
		t.Fatalf("sources[0].message = %q, want %q", got, want)
	}
	// Then the whole wire payload, not just the field we expected the
	// token to be in.
	for n := len(tok); n >= 8; n-- {
		for i := 0; i+n <= len(tok); i++ {
			if strings.Contains(raw, tok[i:i+n]) {
				t.Fatalf("%d-byte token fragment %q reached the tool result: %s", n, tok[i:i+n], raw)
			}
		}
	}
}
