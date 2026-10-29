package main

import (
	"context"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that every tool wakil-ctx advertises has
// an object-typed outputSchema. list_sessions did not: its Out was a bare
// []wakilcore.SessionMeta, which the SDK turned into a top-level
// {"items":…,"type":["null","array"]}, and a validating client rejected the
// call in the Phase 1 acceptance run. See
// mcpxtest.AssertObjectOutputSchemas for why this needs a live ListTools
// round trip rather than a code-review note.
func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"get_context",
		"list_projects",
		"set_project",
		"set_environment",
		"list_environments",
		"list_sessions",
		"get_session",
		"read_session",
		"record_session_parent",
		// set_provider added by Phase 2b-vi Task 9 — the write half of
		// active.json's fourth axis (Task 7).
		"set_provider",
		// list_providers added by Phase 2b-vi Task 12 — the picker's own
		// source, so the app can list what set_provider can switch to.
		"list_providers",
		// list_orgs and create_org added by Phase 2b-viii Task 2 — the
		// org-picker surface's read and write, both reachable with no
		// active org set.
		"list_orgs",
		"create_org",
		// list_machine_providers and adopt_provider added by Phase
		// 2b-viii Task 3 — the last two tools sub-phase 2b-viii needs:
		// enumerate every account on the machine, and bind an existing
		// one into another org as a --share registration.
		"list_machine_providers",
		"adopt_provider",
		// config_tree added by Phase 2e (#198) — the settings pane's one
		// read, and the tool this test most needs to cover: its Out is
		// the deepest nested shape any wakil-ctx tool advertises, four
		// levels of it, and the SDK derives the whole outputSchema from
		// that type.
		"config_tree",
		// update_org added by Phase 2e (#199) — the settings pane's edit
		// of the organisation's three strings.
		"update_org",
		// list_accounts added by Phase 2e (#200) — the settings pane's
		// account table.
		"list_accounts",
		// derive_config_dir added by Phase 2e (#202) — the one-string
		// rule's single home.
		"derive_config_dir",
		// add_provider added by Phase 2e (#204) — the commit, after the
		// mint.
		"add_provider",
		// unlink_provider added by Phase 2e (#206) — the removal that
		// never refuses.
		"unlink_provider",
		// set_database_dsn and remove_database added by Phase 2e (#207) —
		// the database half of the pane.
		"set_database_dsn",
		"remove_database",
		// set_database_connection added by 2e-iv — a database saved as parts, only the password in the Keychain.
		"set_database_connection",
		// set_api_entry, update_api_entry, remove_api_entry and update_database added by
		// 2e-iii — an environment's API entries and a database's rename and revoke-write.
		"set_api_entry",
		"update_api_entry",
		"remove_api_entry",
		"update_database",
		// record_capacity and capacity added by provider capacity — the
		// write of one account's reading and the read every surface uses.
		"record_capacity",
		"capacity",
		// editor_settings, set_editor_settings and set_project_editor_settings added by 3b-v
		// part 1 — the editor's two settings tiers (Decision 38).
		"editor_settings",
		"browser_settings",
		"keyboard", "set_keys",
		"github_pull_requests",
		"git_account_add", "git_account_remove", "git_host_suggestions",
		"git_ssh_keys", "git_key_generate", "git_token_set", "git_key_passphrase_set", "git_account_test",
		"git_device_start", "git_device_poll", "git_gh_logins", "git_gh_import",
		"git_api_access_token_set", "git_api_access_remove", "git_api_access_test",
		// Connections: the operator's own MCP servers, and the Jira token from the app.
		"connection_catalog", "connection_add", "connection_update", "connection_remove",
		"connection_secrets_set", "connection_allow_set", "jira_token_set",
		"connection_signin_start", "connection_signin_wait", "connection_signout",
		"set_project_agent_instructions",
		"set_editor_settings",
		"set_browser_settings",
		"set_project_editor_settings",
		// set_project_pm_key: a project's Jira project, set from Settings (the Ticket tab scopes by it).
		"set_project_pm_key",
		// set_local_provider added by 3b-viii — a local endpoint's URL and operations.
		"set_local_provider",
		// 2e-ii: a project and an environment, created, renamed and
		// removed from Settings.
		"create_project",
		"rename_project",
		"remove_project",
		"create_environment",
		"rename_environment",
		"remove_environment",
		// Workspaces piece 2: how a repo runs.
		"recipe_detect", "recipe_draft_all", "recipe_effective", "recipe_save",
		"recipe_plan", "recipe_ready_wait", "ports_allocate", "compose_override",
		"recipe_prepare", "recipe_run_steps", "recipe_try", "recipe_secret_set",
	})
}

// TestAddProviderAdvertisesTheAgentExecutable — #259.
//
// **The key has to reach the wire, not just the struct.** Every account
// added through the pane was born with no `claudePath`, which made it
// unusable: `setProvider` refuses a record that does not name an agent
// executable, and the pane has no field to add one later because an
// operator never types a path. The surface passes the binary it just ran
// the sign-in and the mint with; this pins that `add_provider` actually
// accepts it, so a rename on either side fails here rather than in an
// operator's hands.
func TestAddProviderAdvertisesTheAgentExecutable(t *testing.T) {
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "schema-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	for _, tool := range res.Tools {
		if tool.Name != "add_provider" {
			continue
		}
		// The SDK types InputSchema as `any`, so the advertised shape is
		// read the way a client reads it: as JSON.
		raw, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatalf("marshal add_provider input schema: %v", err)
		}
		var schema struct {
			Properties map[string]json.RawMessage `json:"properties"`
		}
		if err := json.Unmarshal(raw, &schema); err != nil {
			t.Fatalf("decode add_provider input schema: %v", err)
		}
		if _, ok := schema.Properties["claudePath"]; !ok {
			var got []string
			for name := range schema.Properties {
				got = append(got, name)
			}
			sort.Strings(got)
			t.Fatalf("add_provider does not accept claudePath; it accepts %v", got)
		}
		return
	}
	t.Fatal("add_provider is not advertised at all")
}

// TestLifecycleToolsRequireTheirParameters pins the required params of the
// six 2e-ii tools by their camelCase wire names, so a rename on either side
// fails here rather than in the Settings pane.
func TestLifecycleToolsRequireTheirParameters(t *testing.T) {
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "schema-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	want := map[string][]string{
		"create_project":     {"folder", "name"},
		"rename_project":     {"name", "newName"},
		"remove_project":     {"name"},
		"create_environment": {"projectPath"},
		"rename_environment": {"projectPath", "name", "newName"},
		"remove_environment": {"projectPath", "name"},
	}
	for _, tool := range res.Tools {
		need, ok := want[tool.Name]
		if !ok {
			continue
		}
		raw, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatalf("marshal %s input schema: %v", tool.Name, err)
		}
		var schema struct {
			Required []string `json:"required"`
		}
		if err := json.Unmarshal(raw, &schema); err != nil {
			t.Fatalf("decode %s input schema: %v", tool.Name, err)
		}
		got := append([]string(nil), schema.Required...)
		sort.Strings(got)
		exp := append([]string(nil), need...)
		sort.Strings(exp)
		if !reflect.DeepEqual(got, exp) {
			t.Errorf("%s requires %v, want %v", tool.Name, got, exp)
		}
		delete(want, tool.Name)
	}
	for name := range want {
		t.Errorf("%s is not advertised", name)
	}
}

// TestGitAccountReadsNeedNoHost pins that the sheet's four reads take what the app sends — the
// organisation's id (and, for Sign in, the provider) — and no host: they asked for one, and every
// call was refused by its own schema, so "A key from ~/.ssh" listed nothing (3a-iii e2e audit).
func TestGitAccountReadsNeedNoHost(t *testing.T) {
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "schema-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	for name, args := range map[string]map[string]any{
		"git_host_suggestions": {"id": "initech"},
		"git_ssh_keys":         {"id": "initech"},
		"git_gh_logins":        {"id": "initech"},
		"git_device_start":     {"id": "initech", "provider": "github"},
		"config_tree":          {"id": "initech"},
	} {
		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
		text := ""
		if err != nil {
			text = err.Error()
		} else if res.IsError && len(res.Content) > 0 {
			if c, ok := res.Content[0].(*mcp.TextContent); ok {
				text = c.Text
			}
		}
		if strings.Contains(text, "missing properties") || strings.Contains(text, "validating") {
			t.Errorf("%s refused by its schema: %s", name, text)
		}
	}
}
