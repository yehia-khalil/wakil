package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that every tool wakil-http advertises
// has an object-typed outputSchema. This server had no slice-typed Out to
// begin with; the assertion is here so the invariant holds for the whole
// fleet rather than only for the three servers that were caught breaking
// it. See mcpxtest.AssertObjectOutputSchemas.
func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"request",
		// list_apis added by #183. It wraps its slice in ApiList for
		// exactly the reason this test exists.
		"list_apis",
		// send added by #187. It returns the same HTTPResult request
		// does, so it is object-typed for the same reason.
		"send",
		// parse_curl and locate_api_url added by Amendment 11.
		"parse_curl",
		"locate_api_url",
	})
}
