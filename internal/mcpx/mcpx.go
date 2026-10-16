// Package mcpx holds MCP-SDK-facing helpers shared across Wakil's cmd/
// servers. It exists specifically so wakilcore — which every server and
// every driver depends on — never needs to import the MCP SDK itself;
// only the handful of cmd/ binaries that actually speak MCP do.
package mcpx

import (
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// ToolErr converts err into an MCP tool-error result carrying a single
// human sentence — never a raw stack trace. A wakilcore.UserError's
// message is surfaced verbatim; any other error is wrapped in one
// sentence, prefixed with server (the calling binary's name, e.g.
// "wakil-ctx" or "wakil-db"), that still includes the original error
// text, so operators can debug it while callers only ever see clean
// prose. If err is nil, ToolErr returns nil.
//
// Handlers must return this result alongside a nil error: if a handler
// returns a non-nil error, the SDK itself sets IsError and copies the raw
// error string into Content, which is exactly the leak this helper exists
// to prevent.
//
// Known SDK consequence (accepted, not a bug to fix here): mcp.AddTool's
// generated handler (go-sdk mcp/server.go, ToolHandlerFor's returned
// closure, roughly lines 401-441 in v1.7.0) marshals the handler's typed
// Out value into CallToolResult.StructuredContent whenever the handler's
// own `error` return is nil — which it always is for a ToolErr-based
// error result, since the error is carried inside the *CallToolResult
// instead. What that payload actually looks like on the wire depends on
// whether Out's JSON zero value marshals to an object or not:
//
//   - For a struct-typed Out (e.g. wakilcore.Rows, wakilcore.Schema), the
//     zero value marshals to a JSON object (e.g.
//     `{"columns":null,"rows":null,"millis":0}`), so every error result
//     ships that object as structuredContent. Every tool in every cmd/
//     server now marshals to an object on both paths — as a struct, a
//     pointer to one (wakil-ctx's get_context, whose nil *Resolved
//     marshals as the zero struct, not as null), or a map — and must stay
//     that way; see the no-slice-typed-Out rule below.
//   - For a slice-typed Out, the zero value is a nil slice, which marshals
//     to the JSON literal `null` rather than an object, so no
//     structuredContent object is produced at all and the SDK appends a
//     second Content block whose text is the literal string "null" next to
//     the clean sentence this helper built. That artifact is only the
//     visible half of the problem; the fatal half is on the SUCCESS path,
//     below.
//
// A MAP-typed field inside Out goes further than an artifact and breaks
// the call outright, which Task 16 hit and this note exists to stop the
// next server rediscovering: the SDK does not merely marshal Out, it
// VALIDATES the marshaled value against the tool's generated output
// schema, on the error path too. A nil map marshals to JSON null against
// an "object"-typed property and fails that validation. Reproduced
// against the SDK with wakilcore.RecallOutput, the client-side error is
// exactly:
//
//	calling "tools/call": validating tool output: validating root: validating /properties/groups: type: <invalid reflect.Value> has type "null", want "object"
//
// The `<invalid reflect.Value>` segment is part of the real string — the
// SDK formatting a zero reflect.Value for the offending instance — and
// not an elision by whoever quoted it. The whole CallToolResult is
// discarded, so the caller gets that protocol-level error about JSON
// schemas INSTEAD OF the clean sentence this helper built, not alongside
// it. A nil SLICE field does not have this problem: the generated schema
// for one is {"items":…,"type":["null","array"]}, which accepts null,
// which is why wakil-db's zero-valued wakilcore.Rows passes. Nor does a
// nil map declared as Out ITSELF rather than as a field of Out — measured
// against wakil-ctx's list_environments (Out map[string]bool) with no
// active project, the error result came back carrying
// `"structuredContent":{}` and no validation error. The fix for the
// broken case is to pass an Out whose maps are non-nil rather than a bare
// zero value — see wakilcore.EmptyRecallOutput and cmd/wakil-recall's
// handler.
//
// NEVER declare a slice-typed Out. Wrap the slice in a struct instead.
// This is a rule about the SUCCESS path and it is not cosmetic. MCP
// requires structuredContent to be a JSON OBJECT, and the SDK generates
// the tool's advertised outputSchema straight from Out — so a slice-typed
// Out advertises a top-level {"items":…,"type":["null","array"]} and then
// ships a bare array. A validating client rejects the whole call. Read
// back through ListTools against the real servers, that is exactly what
// wakil-db's list_databases and list_tables and wakil-ctx's list_sessions
// advertised, and all three failed with a schema/validation error in the
// Phase 1 acceptance run while every object-typed tool in the same
// servers (query, describe_table, get_context, list_projects,
// list_environments) worked. Such a tool is not degraded, it is unusable.
//
// An earlier version of this comment recorded a ruling that the array
// shape was a tolerable cosmetic artifact and that the only alternative
// was declaring Out as `any`, forfeiting the schema. Both halves were
// wrong — the consequence is a broken tool, and wrapping the slice in a
// struct keeps a full, precise item schema AND yields an object — so the
// ruling is deleted rather than softened. The wrappers are
// wakilcore.DatabaseList, wakilcore.ContainerList and
// wakilcore.SessionList, alongside wakilcore.IssuePage and
// wakilcore.RecallOutput, which had the shape right from the start.
// Wrapping also buys somewhere to put a completeness signal, which a bare
// slice has no room for. Every cmd/ server has a test
// (TestOutputSchemasAreObjects, via mcpxtest.AssertObjectOutputSchemas)
// asserting that every tool it advertises has an outputSchema of exactly
// "type":"object"; keep it passing.
//
// Practical upshot on the error path, unchanged by any of the above: a
// client that prefers structuredContent over Content/IsError could
// misread a failed query as "0 rows" rather than "errored" if it does not
// also check IsError. Wrapping does not fix that, and cannot — checking
// IsError is the caller's job.
func ToolErr(server string, err error) *mcp.CallToolResult {
	if err == nil {
		return nil
	}
	msg, ok := wakilcore.IsUserError(err)
	if !ok {
		msg = fmt.Sprintf("%s: an internal error occurred: %s", server, err.Error())
	}
	return &mcp.CallToolResult{
		IsError: true,
		Content: []mcp.Content{&mcp.TextContent{Text: msg}},
	}
}
