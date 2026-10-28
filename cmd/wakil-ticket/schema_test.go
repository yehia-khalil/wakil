package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

// TestOutputSchemasAreObjects pins that each of wakil-ticket's thirteen tools advertises an
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
		"ticket_drafts",
		"ticket_draft_write",
		"ticket_handoff_write",
		"ticket_handoff_defaults",
		"ticket_handoff_may_push",
	})
}
