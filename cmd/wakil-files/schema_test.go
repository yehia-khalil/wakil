package main

import (
	"testing"

	"github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest"
)

func TestOutputSchemasAreObjects(t *testing.T) {
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{"files_list", "files_list_dir", "files_search", "files_replace_text", "files_replace", "files_read", "files_write"})
}
