package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// recallArg is the "recall" tool's only input. The jsonschema tag spells
// out the character restrictions wakilcore.Recall enforces (see
// validateRecallQuery) up front, so a caller sees them in the tool's own
// schema rather than discovering them by having a query rejected.
//
// That tag HAND-ENUMERATES validateRecallQuery's rules; nothing derives
// one from the other and no test pins the prose (emptying the tag leaves
// the suite green — accepted, because a test asserting on description
// text would be brittle without catching anything a reader would not).
// So it is a manual obligation: change what validateRecallQuery rejects,
// change this tag in the same commit, or the schema starts advertising a
// contract the code no longer has.
type recallArg struct {
	Query string `json:"query" jsonschema:"plain-text words to search for across the active project's bound sources; must not be empty and must not contain a quote (\" or '), a backslash, or control characters — these cannot be expressed in the underlying query language and are rejected rather than escaped"`
}

// newServer builds the wakil-recall MCP server with its one tool
// registered. Extracted from main so it (and the handler it wires up) is
// reachable from tests, mirroring cmd/wakil-db, cmd/wakil-pm and
// cmd/wakil-http.
func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-recall", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "recall", Description: "Search every source bound to the active project (Jira only in Phase 1) and return grouped, cited results — no unified ranking and no index, just each source's own answer under its own name. Read the sources array before reporting on the groups: it has one entry per BOUND source, and a source whose ok is false did NOT answer (message says why — commonly that Jira has not been configured for this org yet), so its empty group means \"unknown\", not \"nothing matched\". A source that is not bound for this project at all appears in neither groups nor sources. A source entry with truncated=true means its answer was cut off, or that completeness could not be confirmed. A source entry with a non-zero filtered dropped that many results for belonging to a different project than the one configured — if filtered is non-zero and the group is empty, do NOT report \"nothing matched\": the configured Jira project key is most likely stale (Jira keeps a renamed project's old key working as a search alias, so the search still matches but every issue comes back under the new key), and the operator should update scopes.pm.projectKey in .wakil/project.json."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recallArg) (*mcp.CallToolResult, wakilcore.RecallOutput, error) {
			out, err := wakilcore.Recall(ctx, a.Query)
			if err != nil {
				// The error result is returned in the FIRST position
				// with a nil error in the third, per mcpx.ToolErr's doc
				// comment: a non-nil third return makes the SDK discard
				// this result and copy err.Error() into Content
				// verbatim, which is the raw-error leak ToolErr exists
				// to prevent. TestRecallSanitizesNonUserError pins the
				// difference on the one failure here that is not
				// already a UserError.
				//
				// The Out value is EmptyRecallOutput(), not a bare
				// RecallOutput{}: the SDK marshals and schema-validates
				// Out even on this path, and a zero RecallOutput's nil
				// Groups map fails that validation outright — see
				// EmptyRecallOutput's doc comment.
				//
				// Only a whole-call failure reaches this branch — no
				// active project, or a query wakilcore refused to send
				// anywhere. A bound source that fails is reported
				// inside a SUCCESSFUL result via RecallOutput.Sources,
				// not here.
				return mcpx.ToolErr("wakil-recall", err), wakilcore.EmptyRecallOutput(), nil
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
