package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

func callJSON(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) (map[string]any, string) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	if res.IsError {
		return nil, res.Content[0].(*mcp.TextContent).Text
	}
	b, _ := json.Marshal(res.StructuredContent)
	var out map[string]any
	json.Unmarshal(b, &out)
	return out, ""
}

func TestACheckoutIsMadeRecordedReachedAndRemovedWithItsWorkKept(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	cs := connectedClient(t)

	add, fail := callJSON(t, cs, "git_worktree_add", map[string]any{"root": root, "project": "proj", "slug": "fix-otp", "branch": "fix-otp", "create": true, "from": "HEAD"})
	if fail != "" {
		t.Fatal(fail)
	}
	path := add["path"].(string)
	if !strings.Contains(path, filepath.Join("workspaces", "proj", "fix-otp", filepath.Base(root))) {
		t.Fatalf("path %q", path)
	}
	// Not in the record yet: confinement refuses it.
	if _, fail := callJSON(t, cs, "git_status", map[string]any{"root": path}); fail == "" {
		t.Fatal("an unrecorded checkout was reached")
	}
	rec := []wakilcore.Workspace{{ID: "w1", Name: "Fix OTP", Slug: "fix-otp", Project: "proj", Environment: "local",
		Checkouts: []wakilcore.WorkspaceCheckout{{Repo: root, Path: path, Branch: "fix-otp"}}}}
	if _, fail := callJSON(t, cs, "workspaces_write", map[string]any{"workspaces": rec}); fail != "" {
		t.Fatal(fail)
	}
	if _, fail := callJSON(t, cs, "git_status", map[string]any{"root": path}); fail != "" {
		t.Fatal(fail)
	}
	read, fail := callJSON(t, cs, "workspaces_read", map[string]any{})
	if fail != "" || len(read["workspaces"].([]any)) != 1 {
		t.Fatalf("%v %s", read, fail)
	}
	os.WriteFile(filepath.Join(path, "seed.txt"), []byte("work\n"), 0o644)
	if _, fail := callJSON(t, cs, "git_worktree_remove", map[string]any{"root": root, "path": path}); fail == "" {
		t.Fatal("a dirty checkout was removed without a snapshot")
	}
	rm, fail := callJSON(t, cs, "git_worktree_remove", map[string]any{"root": root, "path": path, "snapshot": "refs/wakil/snapshots/w1/proj"})
	if fail != "" || rm["snapshot"] == "" {
		t.Fatalf("%v %s", rm, fail)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("checkout left")
	}
	// Re-made on the same branch, the work put back.
	if _, fail := callJSON(t, cs, "git_worktree_add", map[string]any{"root": root, "project": "proj", "slug": "fix-otp", "branch": "fix-otp"}); fail != "" {
		t.Fatal(fail)
	}
	if _, fail := callJSON(t, cs, "git_snapshot_apply", map[string]any{"root": path, "ref": "refs/wakil/snapshots/w1/proj"}); fail != "" {
		t.Fatal(fail)
	}
	if b, _ := os.ReadFile(filepath.Join(path, "seed.txt")); string(b) != "work\n" {
		t.Fatalf("seed.txt %q", b)
	}
}

func TestWorktreeAddRefusesACheckoutAsItsRoot(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	cs := connectedClient(t)
	if _, fail := callJSON(t, cs, "git_worktree_add", map[string]any{"root": t.TempDir(), "project": "proj", "slug": "s", "branch": "b", "create": true}); fail == "" {
		t.Fatal("want refusal")
	}
	if _, fail := callJSON(t, cs, "git_worktree_add", map[string]any{"root": root, "project": "proj", "slug": "../x", "branch": "b", "create": true}); fail == "" {
		t.Fatal("want refusal of a slug that escapes")
	}
}

// A new workspace's names step past what is taken: a slug the record names or whose folder exists
// (an orphan), a branch the repo has. The reply says which were used.
func TestWorktreeAddOfANewWorkspaceStepsPastTakenNamesAndDiscardTakesItBack(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	cs := connectedClient(t)
	first, fail := callJSON(t, cs, "git_worktree_add", map[string]any{"root": root, "project": "proj", "slug": "fix-otp", "branch": "fix-otp", "create": true, "from": "HEAD"})
	if fail != "" {
		t.Fatal(fail)
	}
	// The first is never recorded (the walk's orphan): a second with the same title still gets a copy.
	second, fail := callJSON(t, cs, "git_worktree_add", map[string]any{"root": root, "project": "proj", "slug": "fix-otp", "branch": "fix-otp",
		"create": true, "from": "HEAD", "newName": true, "takenSlugs": []string{"fix-otp-2"}})
	if fail != "" {
		t.Fatal(fail)
	}
	if second["slug"] != "fix-otp-3" || second["branch"] != "fix-otp-2" || second["created"] != true {
		t.Fatalf("second %v", second)
	}
	if !strings.Contains(second["path"].(string), filepath.Join("proj", "fix-otp-3", filepath.Base(root))) {
		t.Fatalf("path %v", second["path"])
	}
	// Taken back: folder and branch.
	if _, fail := callJSON(t, cs, "git_worktree_discard", map[string]any{"root": root, "project": "proj", "slug": "fix-otp-3", "branch": "fix-otp-2"}); fail != "" {
		t.Fatal(fail)
	}
	if _, err := os.Stat(second["path"].(string)); !os.IsNotExist(err) {
		t.Fatal("checkout left")
	}
	if _, err := os.Stat(first["path"].(string)); err != nil {
		t.Fatal("discard reached another checkout")
	}
}
