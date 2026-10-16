package mcpx

import (
	"errors"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

func textOf(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	if res == nil {
		t.Fatal("result must not be nil")
	}
	if len(res.Content) != 1 {
		t.Fatalf("expected exactly one content item, got %d", len(res.Content))
	}
	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("expected *mcp.TextContent, got %T", res.Content[0])
	}
	return tc.Text
}

func TestToolErrUserErrorVerbatim(t *testing.T) {
	err := wakilcore.UserError("no active project — run set_project first")
	res := ToolErr("wakil-ctx", err)
	if res == nil {
		t.Fatal("ToolErr must not return a nil result for a non-nil error")
	}
	if !res.IsError {
		t.Fatal("expected IsError to be true")
	}
	got := textOf(t, res)
	if got != "no active project — run set_project first" {
		t.Fatalf("expected message verbatim, got %q", got)
	}
}

func TestToolErrPlainErrorIncludesServerAndText(t *testing.T) {
	err := errors.New("boom: disk full")
	res := ToolErr("wakil-db", err)
	if res == nil {
		t.Fatal("ToolErr must not return a nil result for a non-nil error")
	}
	if !res.IsError {
		t.Fatal("expected IsError to be true")
	}
	got := textOf(t, res)
	if !strings.Contains(got, "boom: disk full") {
		t.Fatalf("expected message to include original error text, got %q", got)
	}
	if !strings.HasPrefix(got, "wakil-db:") {
		t.Fatalf("expected message to be prefixed with the server name, got %q", got)
	}
}

func TestToolErrNilErrorReturnsNil(t *testing.T) {
	if res := ToolErr("wakil-db", nil); res != nil {
		t.Fatalf("expected nil result for nil error, got %+v", res)
	}
}
