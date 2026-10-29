package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// TestListPrintsEachToolWithItsLiveHint: --list dials as serving does and prints every tool with
// the server's word on it now, "" for a tool with no annotations; it never asks the app.
func TestListPrintsEachToolWithItsLiveHint(t *testing.T) {
	setupOrg(t)
	sock := listenSocket(t, `{"decision":"allow"}`)
	t.Setenv("WAKIL_APPROVAL_SOCKET", sock.path)
	addConn(t, github())
	up := &fakeUpstream{}
	var out bytes.Buffer
	if code := list(context.Background(), "initech", "github", up.dial(t), &out); code != 0 {
		t.Fatalf("exit = %d, out %s", code, out.String())
	}
	var got listOut
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("%v: %s", err, out.String())
	}
	want := map[string]string{"read_doc": "readOnly", "list_things": "readOnly", "create_issue": "writes", "delete_repo": "destructive", "plain": ""}
	if len(got.Tools) != len(want) || got.Error != "" {
		t.Fatalf("out = %s", out.String())
	}
	for _, tool := range got.Tools {
		if h, ok := want[tool.Name]; !ok || h != tool.Hint {
			t.Fatalf("%s: hint %q, want %q", tool.Name, tool.Hint, h)
		}
	}
	if !strings.Contains(out.String(), `"plain","hint":""`) {
		t.Fatalf("an empty hint is still printed: %s", out.String())
	}
	if len(sock.requests()) != 0 || len(up.ran()) != 0 {
		t.Fatalf("list asked %v, ran %v", sock.requests(), up.ran())
	}
}

// TestListPrintsTheErrorScrubbed: a server that cannot be reached prints its error whole, less
// any stored secret, and exits 1.
func TestListPrintsTheErrorScrubbed(t *testing.T) {
	setupOrg(t)
	memorySecurity(t)
	addConn(t, github())
	setSecrets(t, "github", map[string]string{"token": "ghp_initech_secret"})
	down := func(context.Context, string, wakilcore.MCPConnection) (mcp.Transport, error) {
		return nil, wakilcore.UserError("401 Unauthorized: bad token ghp_initech_secret")
	}
	var out bytes.Buffer
	if code := list(context.Background(), "initech", "github", down, &out); code != 1 {
		t.Fatalf("exit = %d", code)
	}
	var got listOut
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("%v: %s", err, out.String())
	}
	if got.Error != "401 Unauthorized: bad token [secret]" || got.Tools != nil {
		t.Fatalf("out = %s", out.String())
	}
}
