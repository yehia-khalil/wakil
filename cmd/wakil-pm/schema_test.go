package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that every tool wakil-pm advertises has
// an object-typed outputSchema. This server had no slice-typed Out to begin
// with — wakilcore.IssuePage already wraps its []Issue — and the assertion
// is here so that stays true rather than because it was ever broken. See
// mcpxtest.AssertObjectOutputSchemas.
func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"my_issues",
		"search_issues",
		"get_issue",
	})
}
