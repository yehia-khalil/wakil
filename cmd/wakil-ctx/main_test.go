package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// setupProject writes a minimal project fixture with the given environments
// map (raw JSON fragment, e.g. `"staging":{"databases":[]}`) and registers it
// as the active project. It fails the test hard on any setup error so a
// broken fixture can never produce a green test.
func setupProject(t *testing.T, environmentsJSON string) {
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
}

func TestSetEnvironmentValidates(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)

	if err := setEnvironment("staging"); err != nil {
		t.Fatalf("valid env should pass: %v", err)
	}
	if err := setEnvironment("nope"); err == nil {
		t.Fatal("unknown env must be rejected")
	}
}

func TestSetEnvironmentRejectsUnknownAsUserError(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)

	err := setEnvironment("nope")
	if err == nil {
		t.Fatal("unknown env must be rejected")
	}
	msg, ok := wakilcore.IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
	if msg == "" {
		t.Fatal("UserError message must not be empty")
	}
}

func textOf(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	if res == nil {
		t.Fatal("result must not be nil")
	}
	if len(res.Content) != 1 {
		t.Fatalf("expected exactly one content item, got %d", len(res.Content))
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("expected *mcp.TextContent, got %T", res.Content[0])
	}
	return tc.Text
}

func TestToolErrUserErrorVerbatim(t *testing.T) {
	err := wakilcore.UserError("no active project — run set_project first")
	res := toolErr(err)
	if res == nil {
		t.Fatal("toolErr must not return a nil result")
	}
	if !res.IsError {
		t.Fatal("expected IsError to be true")
	}
	got := textOf(t, res)
	if got != "no active project — run set_project first" {
		t.Fatalf("expected message verbatim, got %q", got)
	}
}

func TestToolErrPlainErrorIncludesText(t *testing.T) {
	err := errors.New("boom: disk full")
	res := toolErr(err)
	if res == nil {
		t.Fatal("toolErr must not return a nil result")
	}
	if !res.IsError {
		t.Fatal("expected IsError to be true")
	}
	got := textOf(t, res)
	if !strings.Contains(got, "boom: disk full") {
		t.Fatalf("expected message to include original error text, got %q", got)
	}
}

// TestGetContextExposesTheActiveProvider is the wire-level companion to
// TestResolveEchoesTheActiveProvider (internal/wakilcore/resolve_test.go):
// it drives the real get_context handler through an in-memory MCP client,
// exactly the path WindowSession (Task 6) will take, and checks that the
// active provider set through WriteActive lands in structuredContent
// under the capitalized "ActiveProvider" key — matching every other
// top-level Resolved field ContextStore.swift already reads (Org,
// Environment, RootPaths).
func TestGetContextExposesTheActiveProvider(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)

	active, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	active.Provider = "main"
	if err := wakilcore.WriteActive(active); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "get-context-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "get_context"})
	if err != nil {
		t.Fatalf("CallTool get_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("get_context returned isError=true: %v", res.Content)
	}

	// Round-trip through JSON rather than a type assertion on
	// StructuredContent directly: what a real client sees is the wire
	// form, and mcpxtest.AssertObjectOutputSchemas already established
	// that pattern for this same reason.
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent: %v", err)
	}
	var structured map[string]any
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent: %v", err)
	}
	if got := structured["ActiveProvider"]; got != "main" {
		t.Fatalf("structuredContent[%q] = %v, want %q\nfull structuredContent: %s", "ActiveProvider", got, "main", raw)
	}
}

// TestGetContextReportsTheRegistryKeyBesideTheName: the registry key and
// project.json's "name" are written independently, and WAKIL_PROJECT is
// looked up by the key (ReadActive), so the app must be told the key — the
// name alone is not something a pin can be built from.
func TestGetContextReportsTheRegistryKeyBesideTheName(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	reg, err := wakilcore.LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	entry := reg["proj"]
	if err := wakilcore.SaveRegistry("initech", map[string]wakilcore.ProjectEntry{"relocated": entry}); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "get-context-key-test", Version: "0.0.0"}, nil).Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "get_context"})
	if err != nil || res.IsError {
		t.Fatalf("get_context: err=%v res=%v", err, res)
	}
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatal(err)
	}
	var structured struct {
		ProjectKey string
		Project    struct {
			Name string `json:"name"`
		}
	}
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatal(err)
	}
	if structured.ProjectKey != "relocated" || structured.Project.Name != "proj" {
		t.Fatalf("ProjectKey = %q, Project.name = %q; want relocated beside proj\nfull: %s", structured.ProjectKey, structured.Project.Name, raw)
	}
}

// TestGetContextReportsOrgAndProviderWhenNoActiveProject is Task 1's own
// wire-level test: a fresh org — WAKIL_ORG set, the org directory
// created, but no active project chosen yet, the first state any new
// operator meets — must not report Org:"" merely because Resolve()
// itself fails for the unrelated reason that no project is active.
// get_context still knows the org (CurrentOrg reads it straight from the
// environment) and, per spec §5.3, the active provider too, so both must
// survive onto the error result via PartialResolved.
//
// Driven through the real get_context handler via newServer(), the same
// in-memory-transport path TestGetContextExposesTheActiveProvider uses,
// rather than calling wakilcore.Resolve()/PartialResolved() directly from
// the test — a helper that reimplemented the handler body would pass even
// if main.go's handler were never touched.
func TestGetContextReportsOrgAndProviderWhenNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "alpha")
	if err := wakilcore.CreateOrg("alpha", wakilcore.Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	// Deliberately no active project: this is the fresh-org case.

	active, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	active.Provider = "main"
	if err := wakilcore.WriteActive(active); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "get-context-partial-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "get_context"})
	if err != nil {
		t.Fatalf("CallTool get_context: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected isError for an org with no active project")
	}

	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent: %v", err)
	}
	var structured map[string]any
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent: %v", err)
	}
	if got := structured["Org"]; got != "alpha" {
		t.Errorf("Org = %v, want %q — the org is knowable and must not be withheld\nfull structuredContent: %s", got, "alpha", raw)
	}
	if got := structured["ActiveProvider"]; got != "main" {
		t.Errorf("ActiveProvider = %v, want %q — spec §5.3 depends on this surviving the error path\nfull structuredContent: %s", got, "main", raw)
	}
}

// TestSetProviderPersists is Task 9's last-mile write test: the fourth
// axis Task 7 gave `ActiveContext` (internal/wakilcore/active.go) had no
// writer anywhere except a hand-built `WriteActive` call in a test, per
// that task's own closing note ("Nothing in this task adds a CLI or
// MCP-tool path to actually write ActiveContext.Provider ... that
// presumably belongs to a later task"). `setActiveProvider` is that
// writer. It must persist the chosen id and leave Project and
// Environment exactly as they were — a provider switch is orthogonal to
// which project or environment is active, the same independence
// TestActiveProviderRoundTrips already pins at the storage layer alone.
func TestSetProviderPersists(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	if err := setEnvironment("staging"); err != nil {
		t.Fatalf("setEnvironment: %v", err)
	}
	cfg := filepath.Join(os.Getenv("HOME"), "cfg")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatalf("mkdir cfg: %v", err)
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "work", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	if err := setActiveProvider("work"); err != nil {
		t.Fatalf("setActiveProvider: %v", err)
	}

	got, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got.Provider != "work" {
		t.Fatalf("Provider = %q, want %q", got.Provider, "work")
	}
	if got.Environment != "staging" {
		t.Fatalf("setActiveProvider must not disturb Environment; got %q", got.Environment)
	}
}

// TestSetProviderRejectsUnknownProviderAsUserError pins that
// setActiveProvider validates the id against the org's registered
// providers (LoadProviderFor) BEFORE ever calling WriteActive. Without
// this check, an operator's typo would persist silently into
// active.json, and the next launch's harness factory (Task 6) would fail
// to find credentials for an account that was never registered, with
// nothing in active.json itself explaining why. The refusal must also be
// a UserError (wakil-ctx's toolErr only strips a raw stack trace for
// that kind) and must leave the previously-persisted state untouched.
func TestSetProviderRejectsUnknownProviderAsUserError(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)

	err := setActiveProvider("nope")
	if err == nil {
		t.Fatal("unknown provider id must be rejected")
	}
	msg, ok := wakilcore.IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
	if msg == "" {
		t.Fatal("UserError message must not be empty")
	}
	got, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got.Provider != "" {
		t.Fatalf("a refused switch must not persist anything; Provider = %q", got.Provider)
	}
}

// TestSetProviderToolPersistsThroughTheWire is the wire-level companion,
// exactly as TestGetContextExposesTheActiveProvider is for get_context's
// ActiveProvider field above: it drives the real set_provider MCP tool
// through an in-memory client, the path WindowModel's ctx_set_provider
// standard action (Task 9, WakilKit) actually takes, rather than calling
// setActiveProvider as a Go function directly.
func TestSetProviderToolPersistsThroughTheWire(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	cfg := filepath.Join(os.Getenv("HOME"), "cfg")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatalf("mkdir cfg: %v", err)
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "work", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "set-provider-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "set_provider", Arguments: map[string]any{"name": "work"},
	})
	if err != nil {
		t.Fatalf("CallTool set_provider: %v", err)
	}
	if res.IsError {
		t.Fatalf("set_provider returned isError=true: %v", res.Content)
	}

	got, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got.Provider != "work" {
		t.Fatalf("Provider = %q, want %q", got.Provider, "work")
	}
}

// TestListProvidersToolReturnsRegisteredProviders is Task 12's own
// wire-level test: acceptance found no path at all from "providers
// registered in the org" to "rows the app's picker can show", and this
// is what proves `list_providers` closes it — driven through the real
// MCP tool, the path `WindowModel.providerPaletteItems` actually takes,
// rather than calling `wakilcore.ListProvidersForCurrentOrg` as a Go
// function directly.
//
// Two providers, not one, so ordering (sorted by id, per
// `ListProvidersFor`'s own doc comment) is pinned rather than merely
// "the one row came back". `work` carries a label; `main` does not — so
// this also pins that an unset label is simply absent from the row
// (`omitempty`) rather than arriving as `""`, which is what a client
// reading it as a required field would otherwise trip on.
func TestListProvidersToolReturnsRegisteredProviders(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	// Two distinct config dirs: AddProvider refuses two providers sharing
	// one (scripts/register-provider.sh pins WAKIL_ORG/WAKIL_PROVIDER
	// inside a config dir, so a second registration would overwrite the
	// first) — see AddProvider's own doc comment.
	mainCfg := filepath.Join(os.Getenv("HOME"), "main-cfg")
	workCfg := filepath.Join(os.Getenv("HOME"), "work-cfg")
	for _, cfg := range []string{mainCfg, workCfg} {
		if err := os.MkdirAll(cfg, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", cfg, err)
		}
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "main", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: mainCfg}); err != nil {
		t.Fatalf("AddProvider main: %v", err)
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "work", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: workCfg, Label: "Work account"}); err != nil {
		t.Fatalf("AddProvider work: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "list-providers-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "list_providers"})
	if err != nil {
		t.Fatalf("CallTool list_providers: %v", err)
	}
	if res.IsError {
		t.Fatalf("list_providers returned isError=true: %v", res.Content)
	}

	// Round-trip through JSON rather than a type assertion on
	// StructuredContent directly — the same reason
	// TestGetContextExposesTheActiveProvider does: what a real client
	// sees is the wire form.
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent: %v", err)
	}
	var structured struct {
		Providers []map[string]any `json:"providers"`
	}
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent: %v\nraw: %s", err, raw)
	}
	if len(structured.Providers) != 2 {
		t.Fatalf("providers = %v, want 2 entries\nraw: %s", structured.Providers, raw)
	}
	if got := structured.Providers[0]["id"]; got != "main" {
		t.Fatalf("providers[0].id = %v, want %q\nraw: %s", got, "main", raw)
	}
	if _, ok := structured.Providers[0]["label"]; ok {
		t.Fatalf("providers[0] (main, no label) carried a label key at all: %s", raw)
	}
	if got := structured.Providers[1]["id"]; got != "work" {
		t.Fatalf("providers[1].id = %v, want %q\nraw: %s", got, "work", raw)
	}
	if got := structured.Providers[1]["kind"]; got != "claude-code" {
		t.Fatalf("providers[1].kind = %v, want %q\nraw: %s", got, "claude-code", raw)
	}
	if got := structured.Providers[1]["label"]; got != "Work account" {
		t.Fatalf("providers[1].label = %v, want %q\nraw: %s", got, "Work account", raw)
	}
	// Never a credential, never a configDir, never a claudePath — the
	// structural narrowing ProviderSummary's own doc comment describes.
	for _, forbidden := range []string{"configDir", "claudePath", "oauthToken", "token"} {
		for _, row := range structured.Providers {
			if _, ok := row[forbidden]; ok {
				t.Fatalf("providers row %v carried forbidden key %q: %s", row, forbidden, raw)
			}
		}
	}
}

// TestListOrgsWorksWithNoOrgSet pins the entire reason listOrgs can live
// on wakil-ctx at all (spec §9.1, probe §3): WAKIL_ORG is unset, exactly
// the operator this tool exists to serve, and it must still enumerate
// every registered org rather than failing the way a CurrentOrg()-backed
// call would. Two orgs, not one, so the sort (ListOrgs' own contract) is
// pinned, and a fresh org's Accounts is checked as 0 rather than merely
// present, since Accounts is a count and "0" and "absent" must not be
// confused.
func TestListOrgsWorksWithNoOrgSet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"alpha", "beta"} {
		if err := wakilcore.CreateOrg(id, wakilcore.Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}
	got, err := listOrgs()
	if err != nil {
		t.Fatalf("listOrgs with WAKIL_ORG unset must succeed: %v", err)
	}
	if len(got.Orgs) != 2 {
		t.Fatalf("len(Orgs) = %d, want 2", len(got.Orgs))
	}
	if got.Orgs[0].ID != "alpha" {
		t.Errorf("Orgs[0].ID = %q, want alpha (sorted)", got.Orgs[0].ID)
	}
	if got.Orgs[0].Accounts != 0 {
		t.Errorf("Accounts = %d, want 0 for a fresh org", got.Orgs[0].Accounts)
	}
}

// TestListOrgsToolWorksWithNoOrgSetThroughTheWire is
// TestListOrgsWorksWithNoOrgSet's wire-level companion: it drives the
// real list_orgs MCP tool through an in-memory client with WAKIL_ORG
// unset, the path the org-picker surface actually takes, rather than
// calling listOrgs as a bare Go function. A helper-only test cannot prove
// the tool is registered and reachable with no org set — which is the
// whole point of this tool — so this is required alongside the helper
// test above, not instead of it.
func TestListOrgsToolWorksWithNoOrgSetThroughTheWire(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"alpha", "beta"} {
		if err := wakilcore.CreateOrg(id, wakilcore.Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "list-orgs-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "list_orgs"})
	if err != nil {
		t.Fatalf("CallTool list_orgs: %v", err)
	}
	if res.IsError {
		t.Fatalf("list_orgs returned isError=true with WAKIL_ORG unset: %v", res.Content)
	}

	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent: %v", err)
	}
	var structured struct {
		Orgs []map[string]any `json:"orgs"`
	}
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent: %v\nraw: %s", err, raw)
	}
	if len(structured.Orgs) != 2 {
		t.Fatalf("orgs = %v, want 2 entries\nraw: %s", structured.Orgs, raw)
	}
	if got := structured.Orgs[0]["id"]; got != "alpha" {
		t.Fatalf("orgs[0].id = %v, want %q\nraw: %s", got, "alpha", raw)
	}
}

// TestCreateOrgWithNoJiraBaseSucceeds pins that the Jira base is
// optional: normaliseOrg skips its validation entirely when it is empty
// (org.go), so an org registered with none at all is legal, not merely
// tolerated by omission.
func TestCreateOrgWithNoJiraBaseSucceeds(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	if err := createOrg(createOrgArgs{ID: "umbrella-eu"}); err != nil {
		t.Fatalf("an org with no Jira base is legal: %v", err)
	}
	o, err := wakilcore.LoadOrgFor("umbrella-eu")
	if err != nil {
		t.Fatalf("LoadOrgFor: %v", err)
	}
	if o.JiraBase != "" {
		t.Errorf("JiraBase = %q, want empty", o.JiraBase)
	}
}

// TestCreateOrgReturnsGoRefusalVerbatim pins that createOrg is a thin
// wrapper: CreateOrg's own validation wording for a non-https Jira base
// must reach the caller unchanged, not be re-worded or re-implemented at
// the tool layer.
func TestCreateOrgReturnsGoRefusalVerbatim(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	err := createOrg(createOrgArgs{ID: "x", JiraBase: "http://nope.example.com"})
	if err == nil {
		t.Fatal("expected a refusal for a non-https Jira base")
	}
	if !strings.Contains(err.Error(), "absolute https URL") {
		t.Errorf("error = %q, want Go's own wording — the form must not re-implement this", err)
	}
}

// TestCreateOrgToolPersistsThroughTheWire is the wire-level companion:
// it drives the real create_org MCP tool through an in-memory client
// with WAKIL_ORG unset — the org plane's whole reason for existing is an
// operator who has not chosen one yet — and confirms the org is
// actually registered on disk afterward.
func TestCreateOrgToolPersistsThroughTheWire(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "create-org-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "create_org", Arguments: map[string]any{"id": "newco"},
	})
	if err != nil {
		t.Fatalf("CallTool create_org: %v", err)
	}
	if res.IsError {
		t.Fatalf("create_org returned isError=true: %v", res.Content)
	}

	if _, err := wakilcore.LoadOrgFor("newco"); err != nil {
		t.Fatalf("LoadOrgFor newco after create_org: %v", err)
	}
}

// TestListMachineProvidersToolSpansOrgsWithNoCredential is
// list_machine_providers' wire-level test: it drives the real MCP tool
// through an in-memory client with WAKIL_ORG unset (this tool must be
// reachable with no active org, same as list_orgs) and confirms the
// listing carries providers from every org plus each row's homeOrg,
// and that no row carries anything resembling a credential — the token
// lives in the Keychain and this tool must never touch it.
func TestListMachineProvidersToolSpansOrgsWithNoCredential(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"personal", "work"} {
		if err := wakilcore.CreateOrg(id, wakilcore.Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}
	dir := filepath.Join(home, "cfg-main")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := wakilcore.AddProvider("personal", wakilcore.Provider{ID: "main", Kind: "claude-code", ConfigDir: dir}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "list-machine-providers-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "list_machine_providers"})
	if err != nil {
		t.Fatalf("CallTool list_machine_providers: %v", err)
	}
	if res.IsError {
		t.Fatalf("list_machine_providers returned isError=true with WAKIL_ORG unset: %v", res.Content)
	}

	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structuredContent: %v", err)
	}
	var structured struct {
		Providers []map[string]any `json:"providers"`
	}
	if err := json.Unmarshal(raw, &structured); err != nil {
		t.Fatalf("unmarshal structuredContent: %v\nraw: %s", err, raw)
	}
	if len(structured.Providers) != 1 {
		t.Fatalf("providers = %v, want 1 entry\nraw: %s", structured.Providers, raw)
	}
	row := structured.Providers[0]
	if row["org"] != "personal" || row["id"] != "main" {
		t.Fatalf("row = %v, want org=personal id=main\nraw: %s", row, raw)
	}
	if row["homeOrg"] != "personal" {
		t.Fatalf("row homeOrg = %v, want personal\nraw: %s", row["homeOrg"], raw)
	}
	for key := range row {
		lower := strings.ToLower(key)
		if strings.Contains(lower, "token") || strings.Contains(lower, "credential") || strings.Contains(lower, "secret") {
			t.Fatalf("row carries a credential-shaped field %q — never allowed on this tool\nraw: %s", key, raw)
		}
	}
}

// TestAdoptProviderToolBindsAsSharedWithoutMovingTheHome is
// adopt_provider's wire-level test: it registers a provider in "home",
// then adopts the same configDir into "other" through the real MCP
// tool, and confirms the resulting record in "other" is Shared and that
// ConfigDirHome(dir) still names "home" — the whole point of #25's
// --share path is that adoption does not move the headless home.
func TestAdoptProviderToolBindsAsSharedWithoutMovingTheHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"home", "other"} {
		if err := wakilcore.CreateOrg(id, wakilcore.Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}
	dir := filepath.Join(home, "cfg-shared")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := wakilcore.AddProvider("home", wakilcore.Provider{ID: "main", Kind: "claude-code", ConfigDir: dir}); err != nil {
		t.Fatalf("AddProvider home: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "adopt-provider-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "adopt_provider",
		Arguments: map[string]any{
			"org": "other", "id": "adopted", "configDir": dir, "kind": "claude-code",
		},
	})
	if err != nil {
		t.Fatalf("CallTool adopt_provider: %v", err)
	}
	if res.IsError {
		t.Fatalf("adopt_provider returned isError=true: %v", res.Content)
	}

	got, err := wakilcore.LoadProviderFor("other", "adopted")
	if err != nil {
		t.Fatalf("LoadProviderFor other/adopted: %v", err)
	}
	if !got.Shared {
		t.Errorf("Shared = false, want true — adopt_provider must always register as a share")
	}

	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	homeOrg, homeID, err := wakilcore.ConfigDirHome(resolved)
	if err != nil {
		t.Fatalf("ConfigDirHome: %v", err)
	}
	if homeOrg != "home" || homeID != "main" {
		t.Errorf("ConfigDirHome = (%q, %q), want (home, main) — adoption must not move the headless home", homeOrg, homeID)
	}
}

// TestAdoptProviderToolRefusesWithoutConfigDir pins that adopt_provider
// still goes through AddProvider's own validation: a claude-code kind
// with no configDir must be refused with Go's own wording, not silently
// accepted with an empty ConfigDir.
func TestAdoptProviderToolRefusesWithoutConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	if err := wakilcore.CreateOrg("other", wakilcore.Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "adopt-provider-refusal-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "adopt_provider",
		Arguments: map[string]any{
			"org": "other", "id": "adopted", "kind": "claude-code",
		},
	})
	if err != nil {
		t.Fatalf("CallTool adopt_provider: %v", err)
	}
	if !res.IsError {
		t.Fatalf("adopt_provider with no configDir must be refused")
	}
}

// list_environments publishes the production FLAG'S EFFECT, so that no
// reader downstream re-derives it by comparing the name. That re-derivation
// is what Decision 26 removes, and a tool that published only readOnly left
// every caller no choice but to do it.
func TestListEnvironmentsPublishesTheFlagsEffectAndItsNotices(t *testing.T) {
	yes, no := true, false
	got := wakilcore.NewEnvironmentList(map[string]wakilcore.Environment{
		"staging":    {},
		"prod":       {Databases: []wakilcore.Database{{Name: "c", WriteRef: "w"}}},
		"blue":       {Production: &yes},
		"production": {Production: &no},
	})

	if got.Environments["blue"].Production != true {
		t.Error("an environment declaring true is production whatever it is named")
	}
	if got.Environments["production"].Production != false {
		t.Error("a production declaring false is honoured")
	}
	if got.Environments["prod"].Production != false {
		t.Error("prod with no flag is not production; the name match is unchanged")
	}
	if got.Environments["staging"].Production != false {
		t.Error("staging is not production")
	}
	if got.Environments["prod"].ReadOnly {
		t.Error("prod holds a writable database")
	}
	if !got.Environments["staging"].ReadOnly {
		t.Error("staging declares nothing and is vacuously read-only")
	}

	// Both surprising shapes are surfaced ON THE ENVIRONMENT they are
	// about, so a surface drawing the listing can put each beside its own
	// row rather than heaping them above the list.
	if n := got.Environments["prod"].Notice; !strings.Contains(n, "Reads like production") {
		t.Errorf("prod's notice is %q", n)
	}
	if n := got.Environments["production"].Notice; !strings.Contains(n, "declares") {
		t.Errorf("the disarm notice is %q", n)
	}
	// And nothing unremarkable carries one.
	for _, name := range []string{"staging", "blue"} {
		if n := got.Environments[name].Notice; n != "" {
			t.Errorf("%s should carry no notice, got %q", name, n)
		}
	}
}

func TestListEnvironmentsIsNeverNilOnTheErrorPath(t *testing.T) {
	// mcpx's ToolErr comment: a nil map inside a struct-typed Out fails
	// schema validation and the caller gets a protocol error INSTEAD of the
	// clean sentence toolErr built. The error path passes nil, so this is
	// the shape that path actually ships.
	got := wakilcore.NewEnvironmentList(nil)
	if got.Environments == nil {
		t.Error("environments must marshal as {} rather than null")
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(b) != `{"environments":{}}` {
		t.Errorf("empty listing marshalled as %s", b)
	}
}

func TestCapacityToolsRecordThenReadThroughTheWire(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	cfg := filepath.Join(os.Getenv("HOME"), "main-cfg")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "main", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "capacity-test-client", Version: "0.0.0"}, nil).
		Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	rec, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "record_capacity", Arguments: map[string]any{
		"provider": "main",
		"fiveHour": map[string]any{"percentLeft": 28, "resetsAt": "2026-10-10T17:20:00Z"},
		"asOf":     "2026-10-10T16:18:00Z",
	}})
	if err != nil || rec.IsError {
		t.Fatalf("record_capacity: err=%v res=%v", err, rec)
	}
	for _, args := range []map[string]any{{"refresh": false}, {}} {
		if r, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "capacity", Arguments: args}); err != nil || r.IsError {
			t.Fatalf("capacity %v: err=%v res=%v", args, err, r)
		}
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "capacity"})
	if err != nil || res.IsError {
		t.Fatalf("capacity: err=%v res=%v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var got wakilcore.CapacityListing
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode: %v (%s)", err, raw)
	}
	if len(got.Readings) != 1 || got.Readings[0].State != "read" || got.Readings[0].FiveHour.PercentLeft != 28 {
		t.Errorf("capacity = %s", raw)
	}
}

// A write through the tool lands in the resolved read, for both tiers.
func TestEditorSettingsRoundTrip(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "editor-settings-test", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	call := func(name string, args map[string]any) *mcp.CallToolResult {
		t.Helper()
		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil {
			t.Fatalf("CallTool %s: %v", name, err)
		}
		return res
	}
	if res := call("set_editor_settings", map[string]any{"fontSize": 16, "autosave": "pause"}); res.IsError {
		t.Fatalf("set_editor_settings: %s", textOf(t, res))
	}
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "tabSize": 2}); res.IsError {
		t.Fatalf("set_project_editor_settings: %s", textOf(t, res))
	}
	if res := call("set_editor_settings", map[string]any{"showIgnored": false}); res.IsError {
		t.Fatalf("set_editor_settings showIgnored: %s", textOf(t, res))
	}
	// An empty list is a real answer ("no heavy folders besides .git"), not an omitted field.
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "heavyFolders": []string{}}); res.IsError {
		t.Fatalf("set_project_editor_settings empty heavyFolders: %s", textOf(t, res))
	}
	if raw, err := os.ReadFile(resolved.ProjectPath); err != nil {
		t.Fatalf("read project.json: %v", err)
	} else if !regexp.MustCompile(`"heavyFolders":\s*\[\s*\]`).Match(raw) {
		t.Errorf("project.json does not hold an empty heavyFolders: %s", raw)
	}
	if hf := wakilcore.LoadEditorSettings().HeavyFolders; hf == nil || len(hf) != 0 {
		t.Errorf("HeavyFolders after an empty write = %#v, want empty non-nil", hf)
	}
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "heavyFolders": []string{"storage"}}); res.IsError {
		t.Fatalf("set_project_editor_settings heavyFolders: %s", textOf(t, res))
	}
	if res := call("set_project_editor_settings", map[string]any{"projectPath": resolved.ProjectPath, "heavyFolders": []string{".git"}}); !res.IsError {
		t.Fatal(".git was accepted as a heavy folder")
	}
	if res := call("set_editor_settings", map[string]any{"fontSize": 99}); !res.IsError {
		t.Fatal("an out-of-range font size was accepted")
	}

	got := wakilcore.LoadEditorSettings()
	want := wakilcore.EditorSettings{FontSize: 16, WordWrap: false, Autosave: "pause", ShowIgnored: false, GhostText: true, InlineBlame: true, TabSize: 2, InsertSpaces: true, HeavyFolders: []string{"storage"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("LoadEditorSettings() = %+v, want %+v", got, want)
	}
	res := call("editor_settings", nil)
	if res.IsError {
		t.Fatalf("editor_settings: %s", textOf(t, res))
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), `"tabSize":2`) || !strings.Contains(string(b), `"fontSize":16`) {
		t.Errorf("editor_settings = %s", b)
	}
}

func TestSetEnvironmentRefusedWhenPinned(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]},"local":{"databases":[]}`)
	for _, pin := range []string{"WAKIL_PROJECT", "WAKIL_ENVIRONMENT"} {
		val := "proj"
		if pin == "WAKIL_ENVIRONMENT" {
			val = "staging"
		}
		t.Run(pin, func(t *testing.T) {
			t.Setenv(pin, val)
			err := setEnvironment("local")
			if err == nil || !strings.Contains(err.Error(), "pinned") {
				t.Fatalf("got %v", err)
			}
			if _, ok := wakilcore.IsUserError(err); !ok {
				t.Fatalf("want a UserError, got %T", err)
			}
		})
	}
}

func TestSetProviderWhilePinnedDoesNotPersistThePins(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	if err := setEnvironment("staging"); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(os.Getenv("HOME"), "cfg")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "work", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_ENVIRONMENT", "local")
	if err := setActiveProvider("work"); err != nil {
		t.Fatalf("setActiveProvider must work in a pinned process: %v", err)
	}
	got, err := wakilcore.ReadActiveUnpinned()
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider != "work" || got.Environment != "staging" {
		t.Fatalf("the file must keep the operator's own values, got %+v", got)
	}
}

func TestUpdateOrgToolWritesTheGitIdentity(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "update-org-git-test", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "update_org", Arguments: map[string]any{"id": "initech", "gitName": "N", "gitEmail": "e@x"},
	})
	if err != nil || res.IsError {
		t.Fatalf("update_org: %v %v", err, res)
	}
	o, err := wakilcore.LoadOrgFor("initech")
	if err != nil || o.GitName != "N" || o.GitEmail != "e@x" {
		t.Fatalf("%+v %v", o, err)
	}
}

// lifecycleClient connects an in-memory client to a fresh server for the
// 2e-ii tools' round trips.
func lifecycleClient(t *testing.T) (context.Context, *mcp.ClientSession) {
	t.Helper()
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "lifecycle-test", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	return ctx, cs
}

func callOK(t *testing.T, ctx context.Context, cs *mcp.ClientSession, name string, args map[string]any) map[string]any {
	t.Helper()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil || res.IsError {
		t.Fatalf("%s: %v %v", name, err, res)
	}
	out, _ := res.StructuredContent.(map[string]any)
	return out
}

func TestProjectToolsRoundTrip(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	folder := filepath.Join(os.Getenv("HOME"), "newproj")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}

	out := callOK(t, ctx, cs, "create_project", map[string]any{"folder": folder, "name": "fresh"})
	path, _ := out["path"].(string)
	if out["name"] != "fresh" || path == "" {
		t.Fatalf("create_project output %v", out)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("project file not written: %v", err)
	}
	reg, err := wakilcore.LoadRegistryFor("initech")
	if err != nil || reg["fresh"].Path != path {
		t.Fatalf("registry %v %v", reg, err)
	}

	callOK(t, ctx, cs, "rename_project", map[string]any{"name": "fresh", "newName": "fresher"})
	reg, _ = wakilcore.LoadRegistryFor("initech")
	if _, old := reg["fresh"]; old || reg["fresher"].Path != path {
		t.Fatalf("after rename %v", reg)
	}

	callOK(t, ctx, cs, "remove_project", map[string]any{"name": "fresher"})
	reg, _ = wakilcore.LoadRegistryFor("initech")
	if _, still := reg["fresher"]; still {
		t.Fatalf("row remains %v", reg)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("remove_project must keep project.json: %v", err)
	}
}

// The UI passes the folder's name; a folder already holding a project.json comes back under
// the file's own name, and the tool answers that one (spec Call 2).
func TestCreateProjectToolAnswersAnAdoptedFilesName(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	folder := filepath.Join(os.Getenv("HOME"), "wakil")
	callOK(t, ctx, cs, "create_project", map[string]any{"folder": folder, "name": "wakil"})
	callOK(t, ctx, cs, "rename_project", map[string]any{"name": "wakil", "newName": "W"})
	callOK(t, ctx, cs, "remove_project", map[string]any{"name": "W"})

	out := callOK(t, ctx, cs, "create_project", map[string]any{"folder": folder, "name": "wakil"})
	if out["name"] != "W" {
		t.Fatalf("create_project answered %v, want the file's name W", out)
	}
	reg, _ := wakilcore.LoadRegistryFor("initech")
	if _, ok := reg["W"]; !ok {
		t.Fatalf("registry %v", reg)
	}
}

func TestEnvironmentToolsRoundTrip(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]},"prod":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	pp := filepath.Join(os.Getenv("HOME"), "proj", ".wakil", "project.json")

	out := callOK(t, ctx, cs, "create_environment", map[string]any{"projectPath": pp})
	name, _ := out["name"].(string)
	if name == "" {
		t.Fatalf("create_environment output %v", out)
	}
	p, err := wakilcore.LoadProject(pp)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := p.Environments[name]; !ok {
		t.Fatalf("%q not written: %v", name, p.Environments)
	}

	callOK(t, ctx, cs, "rename_environment", map[string]any{"projectPath": pp, "name": name, "newName": "qa"})
	p, _ = wakilcore.LoadProject(pp)
	if _, ok := p.Environments["qa"]; !ok {
		t.Fatalf("rename not applied: %v", p.Environments)
	}

	// A fake trash program: the real one resolves the user's own Trash,
	// not $HOME, so it must never run from a test.
	rec := t.TempDir()
	fake := filepath.Join(t.TempDir(), "trash")
	script := "#!/bin/sh\nfor a; do last=\"$a\"; done\ncp \"$last\" '" + rec + "'/\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(wakilcore.SetTrashBinForTest(fake))

	out = callOK(t, ctx, cs, "remove_environment", map[string]any{"projectPath": pp, "name": "qa"})
	trashed, _ := out["trashed"].(string)
	if !strings.HasPrefix(trashed, "project.json (before removing qa ") {
		t.Fatalf("remove_environment output %v", out)
	}
	if _, err := os.Stat(filepath.Join(rec, trashed)); err != nil {
		t.Fatalf("the trash program never got the copy: %v", err)
	}
	p, _ = wakilcore.LoadProject(pp)
	if _, still := p.Environments["qa"]; still {
		t.Fatalf("qa remains: %v", p.Environments)
	}
}

func TestRenameEnvironmentRefusalReachesTheWireVerbatim(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]},"prod":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	pp := filepath.Join(os.Getenv("HOME"), "proj", ".wakil", "project.json")
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "rename_environment", Arguments: map[string]any{"projectPath": pp, "name": "staging", "newName": "prod"},
	})
	if err != nil || !res.IsError {
		t.Fatalf("want a tool error, got %v %v", err, res)
	}
	if got := textOf(t, res); got != wakilcore.RenameEnvironment(pp, "staging", "prod").Error() {
		t.Fatalf("refusal text %q", got)
	}
}

func TestApiEntryToolsRoundTrip(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	pp := filepath.Join(os.Getenv("HOME"), "proj", ".wakil", "project.json")

	callOK(t, ctx, cs, "set_api_entry", map[string]any{
		"projectPath": pp, "environment": "staging", "name": "billing", "baseUrl": "https://api.staging.test",
	})
	p, err := wakilcore.LoadProject(pp)
	if err != nil {
		t.Fatal(err)
	}
	api := p.Environments["staging"].API
	if len(api) != 1 || api[0].Name != "billing" || api[0].BaseURL != "https://api.staging.test" {
		t.Fatalf("after set: %+v", api)
	}

	callOK(t, ctx, cs, "update_api_entry", map[string]any{
		"projectPath": pp, "environment": "staging", "name": "billing", "newName": "payments",
	})
	p, _ = wakilcore.LoadProject(pp)
	api = p.Environments["staging"].API
	if len(api) != 1 || api[0].Name != "payments" || api[0].BaseURL != "https://api.staging.test" {
		t.Fatalf("after rename (base URL must be unchanged): %+v", api)
	}

	callOK(t, ctx, cs, "remove_api_entry", map[string]any{
		"projectPath": pp, "environment": "staging", "name": "payments",
	})
	p, _ = wakilcore.LoadProject(pp)
	if len(p.Environments["staging"].API) != 0 {
		t.Fatalf("entry remains: %+v", p.Environments["staging"].API)
	}
}

func TestUpdateDatabaseToolRenames(t *testing.T) {
	setupProject(t, `"staging":{"databases":[{"name":"core","driver":"mysql","ref":"db:proj:staging:core"}]}`)
	ctx, cs := lifecycleClient(t)
	pp := filepath.Join(os.Getenv("HOME"), "proj", ".wakil", "project.json")

	callOK(t, ctx, cs, "update_database", map[string]any{
		"projectPath": pp, "environment": "staging", "name": "core", "newName": "reports",
	})
	p, _ := wakilcore.LoadProject(pp)
	dbs := p.Environments["staging"].Databases
	if len(dbs) != 1 || dbs[0].Name != "reports" || dbs[0].Ref != "db:proj:staging:core" {
		t.Fatalf("after rename: %+v", dbs)
	}
}

// fakeSecurity points the Keychain tool at a script that accepts every write and
// finds nothing, so the tool under test never reaches the operator's login keychain.
func fakeSecurity(t *testing.T) {
	t.Helper()
	script := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ncase \"$1\" in add-generic-password) exit 0;; esac\nexit 44\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_SECURITY_BINARY", script)
}

func TestSetDatabaseConnectionToolSavesPartsAndTheTreeShowsThem(t *testing.T) {
	setupProject(t, `"staging":{"databases":[{"name":"legacy","driver":"mysql","ref":"db:proj:staging:legacy"}]}`)
	fakeSecurity(t)
	ctx, cs := lifecycleClient(t)
	pp := filepath.Join(os.Getenv("HOME"), "proj", ".wakil", "project.json")

	callOK(t, ctx, cs, "set_database_connection", map[string]any{
		"projectPath": pp, "environment": "staging", "name": "core", "driver": "mysql",
		"host": "db.internal", "port": "3307", "database": "orders", "user": "reader",
		"password": "s3cret-pw",
	})

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "config_tree", Arguments: map[string]any{}})
	if err != nil || res.IsError {
		t.Fatalf("config_tree: %v %v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var tree wakilcore.ConfigTree
	if err := json.Unmarshal(raw, &tree); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "s3cret-pw") {
		t.Fatalf("the tree carries the password: %s", raw)
	}
	var core, legacy *wakilcore.ConfigTreeDatabase
	for _, p := range tree.Projects {
		for _, e := range p.Environments {
			for i := range e.Databases {
				switch e.Databases[i].Name {
				case "core":
					core = &e.Databases[i]
				case "legacy":
					legacy = &e.Databases[i]
				}
			}
		}
	}
	if core == nil || core.Connection == nil || core.Connection.Host != "db.internal" ||
		core.Connection.Port != "3307" || core.Connection.Database != "orders" || core.Connection.User != "reader" {
		t.Fatalf("core after save: %+v", core)
	}
	if legacy == nil || legacy.Connection != nil {
		t.Fatalf("a legacy record must carry no connection: %+v", legacy)
	}
}

func TestSetDatabaseConnectionToolRefusalReachesTheWire(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	fakeSecurity(t)
	ctx, cs := lifecycleClient(t)
	pp := filepath.Join(os.Getenv("HOME"), "proj", ".wakil", "project.json")
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "set_database_connection", Arguments: map[string]any{
		"projectPath": pp, "environment": "staging", "name": "core", "driver": "mysql",
	}})
	if err != nil || !res.IsError {
		t.Fatalf("a connection with no host must be refused: %v %v", err, res)
	}
}

// memorySecurity points the Keychain tool at a script that keeps each item in a file, so a
// test can write a secret and see the tree report it present, without the login keychain.
func memorySecurity(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	body := `#!/bin/sh
d="` + dir + `"
cmd=$1; shift
svc=""; val=""; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc=$2; shift;;
    -w) if [ "$cmd" = add-generic-password ]; then val=$2; shift; else mode=w; fi;;
  esac
  shift
done
f="$d/$(printf '%s' "$svc" | tr '/:' '__')"
case $cmd in
  add-generic-password) printf '%s' "$val" > "$f"; exit 0;;
  delete-generic-password) rm -f "$f"; exit 0;;
  find-generic-password) [ -f "$f" ] || exit 44; if [ "$mode" = w ]; then cat "$f"; echo; fi; exit 0;;
esac
exit 1
`
	script := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_SECURITY_BINARY", script)
}

func treeOf(t *testing.T, ctx context.Context, cs *mcp.ClientSession) (wakilcore.ConfigTree, string) {
	t.Helper()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "config_tree", Arguments: map[string]any{}})
	if err != nil || res.IsError {
		t.Fatalf("config_tree: %v %v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var tree wakilcore.ConfigTree
	if err := json.Unmarshal(raw, &tree); err != nil {
		t.Fatal(err)
	}
	return tree, string(raw)
}

func TestConnectionToolsRoundTrip(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)

	out := callOK(t, ctx, cs, "connection_add", map[string]any{"id": "initech", "kind": "datadog", "values": map[string]any{"site": "datadoghq.eu"}})
	if out["name"] != "datadog" {
		t.Fatalf("add answered %v", out)
	}
	tree, _ := treeOf(t, ctx, cs)
	conns := tree.Org.Connections
	if len(conns) != 1 || conns[0].Transport != "http" || conns[0].SignIn != "fields" ||
		conns[0].Title != "Datadog" || conns[0].Values["site"] != "datadoghq.eu" || conns[0].SignedIn {
		t.Fatalf("tree connections %+v", conns)
	}
	secretFields := 0
	for _, f := range conns[0].Fields {
		if f.Secret {
			secretFields++
		}
	}
	if len(conns[0].Fields) != 3 || secretFields != 2 {
		t.Fatalf("fields %+v", conns[0].Fields)
	}

	callOK(t, ctx, cs, "connection_secrets_set", map[string]any{"id": "initech", "name": "datadog", "values": map[string]any{"apiKey": "k-1"}})
	callOK(t, ctx, cs, "connection_update", map[string]any{"id": "initech", "name": "datadog", "newName": "dd", "values": map[string]any{"site": "datadoghq.com"}})
	if got, err := wakilcore.ConnectionSecrets("initech", "dd"); err != nil || got["apiKey"] != "k-1" {
		t.Fatalf("the secret did not move to conn:dd: %v %v", got, err)
	}
	if got, err := wakilcore.ConnectionSecrets("initech", "datadog"); err != nil || len(got) != 0 {
		t.Fatalf("conn:datadog is still there: %v %v", got, err)
	}
	callOK(t, ctx, cs, "connection_allow_set", map[string]any{"id": "initech", "name": "dd", "tool": "search_logs", "allow": true})
	tree, _ = treeOf(t, ctx, cs)
	conns = tree.Org.Connections
	if len(conns) != 1 || conns[0].Name != "dd" || conns[0].Values["site"] != "datadoghq.com" || !conns[0].Allow["search_logs"] {
		t.Fatalf("after edit %+v", conns)
	}

	callOK(t, ctx, cs, "connection_remove", map[string]any{"id": "initech", "name": "dd"})
	tree, _ = treeOf(t, ctx, cs)
	if len(tree.Org.Connections) != 0 {
		t.Fatalf("after remove %+v", tree.Org.Connections)
	}
}

func TestConnectionAddCustomNeedsATransportAndAnAddress(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	for _, args := range []map[string]any{
		{"id": "initech", "kind": "custom", "url": "https://x.test/mcp"},
		{"id": "initech", "kind": "custom", "transport": "http"},
	} {
		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "connection_add", Arguments: args})
		if err != nil || !res.IsError {
			t.Fatalf("%v accepted: %v %v", args, err, res)
		}
	}
	out := callOK(t, ctx, cs, "connection_add", map[string]any{"id": "initech", "kind": "custom", "name": "wiki", "transport": "stdio", "command": "wiki-mcp", "args": []string{"--serve"}})
	if out["name"] != "wiki" {
		t.Fatalf("add answered %v", out)
	}
	c, _ := wakilcore.ConnectionFor("initech", "wiki")
	if c.SignIn != "none" || c.Command != "wiki-mcp" || len(c.Args) != 1 {
		t.Fatalf("stored %+v", c)
	}
}

func TestConnectionRecordRefusesASecretValue(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	ctx, cs := lifecycleClient(t)
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "connection_add", Arguments: map[string]any{
		"id": "initech", "kind": "datadog", "values": map[string]any{"apiKey": "k-9f8e7d"},
	}})
	if err != nil || !res.IsError {
		t.Fatalf("a secret value was accepted into the record: %v %v", err, res)
	}
	raw, _ := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".wakil", "orgs", "initech", "org.json"))
	if strings.Contains(string(raw), "k-9f8e7d") {
		t.Fatalf("org.json carries the secret: %s", raw)
	}
}

func TestConfigTreeNeverCarriesSecrets(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)
	callOK(t, ctx, cs, "connection_add", map[string]any{"id": "initech", "kind": "github"})
	callOK(t, ctx, cs, "connection_secrets_set", map[string]any{"id": "initech", "name": "github", "values": map[string]any{"token": "ghp-s3cret-token"}})
	callOK(t, ctx, cs, "jira_token_set", map[string]any{"id": "initech", "email": "ann@initech.test", "token": "jira-s3cret-token"})

	tree, raw := treeOf(t, ctx, cs)
	for _, secret := range []string{"ghp-s3cret-token", "jira-s3cret-token"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("the tree carries %s: %s", secret, raw)
		}
	}
	if len(tree.Org.Connections) != 1 || !tree.Org.Connections[0].SignedIn || !tree.Org.JiraTokenStored {
		t.Fatalf("presence not reported: %+v stored=%v", tree.Org.Connections, tree.Org.JiraTokenStored)
	}
}

func TestBrowserConnectionIsSignedInOnlyWithAnAccessToken(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)
	callOK(t, ctx, cs, "connection_add", map[string]any{"id": "initech", "kind": "slack"})
	callOK(t, ctx, cs, "connection_secrets_set", map[string]any{"id": "initech", "name": "slack", "values": map[string]any{"clientSecret": "cs-1"}})
	if tree, _ := treeOf(t, ctx, cs); tree.Org.Connections[0].SignedIn {
		t.Fatal("a client secret alone is not a sign-in")
	}
	callOK(t, ctx, cs, "connection_secrets_set", map[string]any{"id": "initech", "name": "slack", "values": map[string]any{"access": "at-1"}})
	if tree, _ := treeOf(t, ctx, cs); !tree.Org.Connections[0].SignedIn {
		t.Fatal("an access token is a sign-in")
	}
}

func TestConnectionSignInToolsNeedAFlowAndSignOutKeepsTheApp(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)
	callOK(t, ctx, cs, "connection_add", map[string]any{"id": "initech", "kind": "slack"})
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "connection_signin_wait", Arguments: map[string]any{"id": "initech", "name": "slack"}})
	if err != nil || !res.IsError {
		t.Fatalf("a wait with no sign-in started: %v %v", err, res)
	}
	res, err = cs.CallTool(ctx, &mcp.CallToolParams{Name: "connection_signin_start", Arguments: map[string]any{"id": "initech", "name": "slack"}})
	if err != nil || !res.IsError {
		t.Fatalf("slack started without its app's client id and secret: %v %v", err, res)
	}
	callOK(t, ctx, cs, "connection_secrets_set", map[string]any{"id": "initech", "name": "slack", "values": map[string]any{
		"clientId": "app-1", "clientSecret": "cs-1", "access": "at-1", "refresh": "rt-1", "client": "{}"}})
	callOK(t, ctx, cs, "connection_signout", map[string]any{"id": "initech", "name": "slack"})
	got, err := wakilcore.ConnectionSecrets("initech", "slack")
	if err != nil || len(got) != 2 || got["clientId"] != "app-1" || got["clientSecret"] != "cs-1" {
		t.Fatalf("after sign-out %v %v", got, err)
	}
}

func TestJiraTokenSetStoresOneLine(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)
	callOK(t, ctx, cs, "jira_token_set", map[string]any{"id": "initech", "email": "ann@initech.test", "token": "tok-1"})
	got, err := wakilcore.SecretGetFor("initech", "jira:initech")
	if err != nil || got != "ann@initech.test:tok-1" {
		t.Fatalf("stored %q %v", got, err)
	}
	for _, args := range []map[string]any{
		{"id": "initech", "email": "a:b@initech.test", "token": "t"},
		{"id": "initech", "email": "", "token": "t"},
		{"id": "initech", "email": "a@initech.test", "token": ""},
	} {
		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "jira_token_set", Arguments: args})
		if err != nil || !res.IsError {
			t.Fatalf("%v accepted", args)
		}
	}
}

// config_tree with an id reads that organisation, not the active one: a session launching in
// another organisation than the window's reads its own connections.
func TestConfigTreeReadsTheNamedOrganisation(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)
	if err := wakilcore.CreateOrg("umbrella", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
	callOK(t, ctx, cs, "connection_add", map[string]any{"id": "umbrella", "kind": "datadog", "values": map[string]any{"site": "datadoghq.eu"}})

	active, _ := treeOf(t, ctx, cs)
	if active.Org.ID != "initech" || len(active.Org.Connections) != 0 {
		t.Fatalf("no id should read the active org, got %q with %d connections", active.Org.ID, len(active.Org.Connections))
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "config_tree", Arguments: map[string]any{"id": "umbrella"}})
	if err != nil || res.IsError {
		t.Fatalf("config_tree: %v %v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var tree wakilcore.ConfigTree
	if err := json.Unmarshal(raw, &tree); err != nil {
		t.Fatal(err)
	}
	if tree.Org.ID != "umbrella" || len(tree.Org.Connections) != 1 {
		t.Fatalf("id=umbrella read %q with %d connections", tree.Org.ID, len(tree.Org.Connections))
	}
}

// TestConnectionUpdateRecordsHints: Settings records what wakil-connect --list read, the whole
// map, so a tool the server dropped goes; the tree then names the stored secret keys (never their
// values) and a custom server's arguments.
func TestConnectionUpdateRecordsHints(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	memorySecurity(t)
	ctx, cs := lifecycleClient(t)
	callOK(t, ctx, cs, "connection_add", map[string]any{"id": "initech", "kind": "custom", "name": "wiki", "transport": "stdio", "command": "wiki-mcp", "args": []string{"--serve"}})
	callOK(t, ctx, cs, "connection_update", map[string]any{"id": "initech", "name": "wiki", "hints": map[string]any{"old_tool": "readOnly"}})
	callOK(t, ctx, cs, "connection_update", map[string]any{"id": "initech", "name": "wiki", "hints": map[string]any{"read_page": "readOnly", "drop_page": "destructive", "plain": ""}})
	callOK(t, ctx, cs, "connection_secrets_set", map[string]any{"id": "initech", "name": "wiki", "values": map[string]any{"env:WIKI_TOKEN": "w-1"}})
	tree, raw := treeOf(t, ctx, cs)
	c := tree.Org.Connections[0]
	if len(c.Hints) != 3 || c.Hints["read_page"] != "readOnly" || c.Hints["drop_page"] != "destructive" || c.Hints["old_tool"] != "" {
		t.Fatalf("hints %v", c.Hints)
	}
	if len(c.Args) != 1 || c.Args[0] != "--serve" || len(c.SecretKeys) != 1 || c.SecretKeys[0] != "env:WIKI_TOKEN" {
		t.Fatalf("args %v keys %v", c.Args, c.SecretKeys)
	}
	if strings.Contains(raw, "w-1") {
		t.Fatalf("a secret value reached the tree: %s", raw)
	}
}

// stubGitHubDevice answers GitHub's device token endpoint with an approval, so no test reaches the
// network.
type stubGitHubDevice struct{}

func (stubGitHubDevice) RoundTrip(r *http.Request) (*http.Response, error) {
	return &http.Response{
		StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Request: r,
		Body: io.NopCloser(strings.NewReader(`{"access_token":"tok-device"}`)),
	}, nil
}

func TestDevicePollAPIAccessDoesNotRewriteMethod(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	memorySecurity(t)
	if err := wakilcore.CreateOrg("initech", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
	wakilcore.AddGitAccount("initech", wakilcore.GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k/id", User: "dev-initech"})
	old := http.DefaultTransport
	http.DefaultTransport = stubGitHubDevice{}
	t.Cleanup(func() { http.DefaultTransport = old })
	ctx, cs := lifecycleClient(t)

	out := callOK(t, ctx, cs, "git_device_poll", map[string]any{
		"id": "initech", "provider": "github", "host": "github.com", "deviceCode": "dc", "apiAccess": true})
	if out["done"] != true {
		t.Fatalf("poll = %v", out)
	}
	a, _ := wakilcore.GitAccountFor("initech", "github.com")
	if a.Method != "ssh" || a.APIAccess != "signin" || a.KeyPath != "/k/id" || a.User != "dev-initech" {
		t.Fatalf("account = %+v", a)
	}
	if tok, err := wakilcore.GitHubTokenFor("initech", "github.com"); err != nil || tok != "tok-device" {
		t.Fatalf("token %q %v", tok, err)
	}

	// Without apiAccess a Sign in still replaces the account, as before.
	callOK(t, ctx, cs, "git_device_poll", map[string]any{"id": "initech", "provider": "github", "host": "github.com", "deviceCode": "dc"})
	if a, _ := wakilcore.GitAccountFor("initech", "github.com"); a.Method != "signin" || a.APIAccess != "" {
		t.Fatalf("account = %+v", a)
	}
}

func TestGitAPIAccessToolsRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "")
	memorySecurity(t)
	if err := wakilcore.CreateOrg("initech", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
	wakilcore.AddGitAccount("initech", wakilcore.GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k/id"})
	ctx, cs := lifecycleClient(t)
	callOK(t, ctx, cs, "git_api_access_token_set", map[string]any{"id": "initech", "host": "github.com", "token": "ghp-x"})
	if a, _ := wakilcore.GitAccountFor("initech", "github.com"); a.Method != "ssh" || a.APIAccess != "token" {
		t.Fatalf("account = %+v", a)
	}
	callOK(t, ctx, cs, "git_api_access_remove", map[string]any{"id": "initech", "host": "github.com"})
	if a, _ := wakilcore.GitAccountFor("initech", "github.com"); a.Method != "ssh" || a.APIAccess != "" {
		t.Fatalf("account = %+v", a)
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "git_api_access_test", Arguments: map[string]any{"id": "initech", "host": "github.com"}})
	if err != nil || !res.IsError {
		t.Fatalf("a test with no API access must be refused: %v %v", err, res)
	}
}
