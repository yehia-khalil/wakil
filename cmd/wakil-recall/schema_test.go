package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that every tool wakil-recall advertises
// has an object-typed outputSchema. This server had no slice-typed Out to
// begin with — wakilcore.RecallOutput already wraps its groups and sources
// — and the assertion is here so that stays true rather than because it was
// ever broken. See mcpxtest.AssertObjectOutputSchemas.
func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"recall",
	})
}
