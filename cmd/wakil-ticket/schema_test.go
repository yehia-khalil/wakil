package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that each of wakil-ticket's eight tools advertises an
// object-typed outputSchema. See mcpxtest.AssertObjectOutputSchemas.
func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"ticket_branch",
		"ticket_in_flight",
		"ticket_record",
		"ticket_record_write",
		"ticket_link",
		"review_reply",
		"review_resolve",
		"review_thread",
	})
}
