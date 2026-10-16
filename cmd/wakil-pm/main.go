package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// emptyArg is deliberately empty: my_issues takes no parameters — it
// always lists issues assigned to the current user in the active
// project's Jira scope. See wakil-db's listDatabasesArg for the same
// reasoning: a struct that advertised an unused input property would
// mislead a caller trying to filter results.
type emptyArg struct{}

type searchArg struct {
	JQL string `json:"jql,omitempty" jsonschema:"extra JQL, ANDed inside the active project's automatic scope; must have balanced parentheses/quotes and must not contain a backslash"`
}

type issueArg struct {
	Key string `json:"key" jsonschema:"issue key, e.g. RAF-142; must belong to the active project"`
}

// projectKey resolves the active project's configured Jira project key.
// It is a pure configuration lookup — no network or Keychain access — so
// a missing project/environment/scope is reported without any side
// effect, before NewJiraFromEnv ever touches the Keychain.
func projectKey() (string, error) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return "", err
	}
	if r.Project.Scopes.PM == nil || r.Project.Scopes.PM.ProjectKey == "" {
		return "", wakilcore.UserError("this project has no Jira scope configured")
	}
	return r.Project.Scopes.PM.ProjectKey, nil
}

// newServer builds the wakil-pm MCP server with all three tools
// registered. Extracted from main so it (and the tools it wires up) is
// reachable from tests, mirroring cmd/wakil-db/main.go's newServer.
func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-pm", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "my_issues", Description: "Issues assigned to you in the active project's Jira scope. Returns at most one page of results. The truncated field is omitted from the response entirely when false, and present (true) when either more issues exist beyond this page OR completeness could not be confirmed at all — so a response with zero issues and truncated=true is not a contradiction, it means Jira gave no way to confirm the list was complete, not that more issues are known to exist. A non-zero filtered field means Jira returned one or more issues outside the active project that were dropped before being returned — not an error, but worth noting if it happens."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ emptyArg) (*mcp.CallToolResult, wakilcore.IssuePage, error) {
			key, err := projectKey()
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.IssuePage{}, nil
			}
			c, err := wakilcore.NewJiraFromEnv()
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.IssuePage{}, nil
			}
			out, err := c.MyIssues(ctx, key)
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.IssuePage{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "search_issues", Description: "Search issues, scoped to the active project's Jira project key. The jql argument must have balanced parentheses/quotes and must not contain a backslash (rejected outright); every returned issue is additionally filtered to keys under the active project, so a result can never include another project's issue even if the jql argument did. Returns at most one page. The truncated field is omitted from the response entirely when false, and present (true) when either more issues exist beyond this page OR completeness could not be confirmed at all — so a response with zero issues and truncated=true is not a contradiction, it means Jira gave no way to confirm the list was complete, not that more issues are known to exist. A non-zero filtered field means Jira returned one or more issues outside the active project that were dropped before being returned — not an error, but worth noting if it happens."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a searchArg) (*mcp.CallToolResult, wakilcore.IssuePage, error) {
			key, err := projectKey()
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.IssuePage{}, nil
			}
			c, err := wakilcore.NewJiraFromEnv()
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.IssuePage{}, nil
			}
			out, err := c.SearchIssues(ctx, key, a.JQL)
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.IssuePage{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "get_issue", Description: "Fetch one issue by key. Scoped to the active project: the key's project prefix must match the active project's Jira key, or the call is rejected — reading another project's issue requires switching project. COMMENTS ARE NOT INCLUDED: the result carries only key, summary, status, assignee and url, and no comment is ever fetched. Do not tell the user an issue has no discussion, or summarise its discussion, on the basis of this result — you have not seen its comments."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a issueArg) (*mcp.CallToolResult, wakilcore.Issue, error) {
			key, err := projectKey()
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.Issue{}, nil
			}
			c, err := wakilcore.NewJiraFromEnv()
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.Issue{}, nil
			}
			out, err := c.GetIssue(ctx, key, a.Key)
			if err != nil {
				return mcpx.ToolErr("wakil-pm", err), wakilcore.Issue{}, nil
			}
			return nil, out, nil
		})

	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
