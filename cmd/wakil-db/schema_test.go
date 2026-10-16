package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that every tool wakil-db advertises has
// an object-typed outputSchema. list_databases and list_tables did not:
// their Outs were bare []wakilcore.Database and []wakilcore.Container,
// which the SDK turned into top-level
// {"items":…,"type":["null","array"]} schemas, and a validating client
// rejected both calls in the Phase 1 acceptance run while query and
// describe_table — struct-typed in the same server — worked. See
// mcpxtest.AssertObjectOutputSchemas for why this needs a live ListTools
// round trip rather than a code-review note.
func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"list_databases",
		"list_tables",
		"describe_table",
		"list_columns",
		"query",
		// mutate: the fifth tool, added in 2b-iii. Its Out is
		// wakilcore.Written, a struct, so it satisfies the same
		// object-outputSchema requirement as the other four.
		"mutate",
		// read_table and classify_statement: 2c-ii. Outs are
		// wakilcore.Rows and wakilcore.StatementClass, both structs.
		"read_table",
		"classify_statement",
		// render_update: 2c-ii-b. Out is RenderedUpdate, a struct, for the
		// same reason ContainerList and DatabaseList are: MCP requires
		// structuredContent to be a JSON object.
		"render_update",
	})
}
