package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// setupProject writes a minimal project fixture (one root, ".") with the
// given environments JSON fragment, makes it the active project, and returns
// the project directory, symlink-resolved.
func setupProject(t *testing.T, environmentsJSON, envName string) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	pdir := filepath.Join(home, "proj")
	if err := os.MkdirAll(filepath.Join(pdir, ".wakil"), 0o755); err != nil {
		t.Fatalf("mkdir project dir: %v", err)
	}
	pp := filepath.Join(pdir, ".wakil", "project.json")
	body := `{"name":"proj","org":"initech","roots":[{"path":"."}],"environments":{` + environmentsJSON + `}}`
	if err := os.WriteFile(pp, []byte(body), 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}
	if err := wakilcore.SaveRegistry("initech", map[string]wakilcore.ProjectEntry{"proj": {Path: pp}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}
	if err := wakilcore.SetProjectChecked("proj"); err != nil {
		t.Fatalf("SetProjectChecked: %v", err)
	}
	if envName != "" {
		active, err := wakilcore.ReadActive()
		if err != nil {
			t.Fatalf("ReadActive: %v", err)
		}
		active.Environment = envName
		if err := wakilcore.WriteActive(active); err != nil {
			t.Fatalf("WriteActive: %v", err)
		}
	}
	resolved, err := filepath.EvalSymlinks(pdir)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	return resolved
}

// gitInit makes dir a repository on main with one commit, isolated from the
// machine's git config.
func gitInit(t *testing.T, dir string) {
	t.Helper()
	run := func(args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = dir
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-b", "main")
	if err := os.WriteFile(filepath.Join(dir, "seed.txt"), []byte("seed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "seed.txt")
	run("commit", "-m", "seed")
}

func connectedClient(t *testing.T) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	s := newServer()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := s.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "wakil-git-test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

func TestStatusRefusesARootOutsideTheProject(t *testing.T) {
	setupProject(t, `"local":{}`, "local")
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_status", Arguments: map[string]any{"root": t.TempDir()}})
	if err != nil || !res.IsError {
		t.Fatalf("want a tool error, got %+v %v", res, err)
	}
}

func TestStatusAnswersForTheProjectRoot(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	os.WriteFile(filepath.Join(root, "new.txt"), []byte("x\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_status", Arguments: map[string]any{"root": root}})
	if err != nil || res.IsError {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), `"path":"new.txt"`) || !strings.Contains(string(b), `"group":"untracked"`) {
		t.Fatalf("%s", b)
	}
}

func TestShowReturnsTheWorktreeText(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("edited\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_show", Arguments: map[string]any{"root": root, "path": "seed.txt", "rev": "worktree"}})
	if err != nil || res.IsError {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), "edited") {
		t.Fatalf("%s", b)
	}
}

func TestDiffWithAnEscapingPathIsAToolError(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_diff", Arguments: map[string]any{"root": root, "path": "../x", "side": "changed"}})
	if err != nil || res == nil || !res.IsError {
		t.Fatalf("want a tool error, got %+v %v", res, err)
	}
}

func TestToolListIsTheReadsAndTheWrites(t *testing.T) {
	cs := connectedClient(t)
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range res.Tools {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	want := []string{"git_amend", "git_blob", "git_commit", "git_diff", "git_discard", "git_identity",
		"git_show", "git_stage", "git_stage_hunk", "git_status", "git_undo_commit", "git_unstage"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("tools %v", names)
	}
}

func TestCommitThroughTheToolUsesTheOrganisationsIdentity(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	name, email := "Org Person", "org@example.test"
	if err := wakilcore.UpdateOrg("initech", wakilcore.OrgPatch{GitName: &name, GitEmail: &email}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("changed\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_commit",
		Arguments: map[string]any{"root": root, "message": "via tool", "all": true}})
	if err != nil || res.IsError {
		t.Fatalf("%v %+v", err, res)
	}
	out, _ := exec.Command("git", "-C", root, "log", "-1", "--format=%ae|%s").Output()
	if strings.TrimSpace(string(out)) != "org@example.test|via tool" {
		t.Fatalf("log %q", out)
	}
	id, _ := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_identity",
		Arguments: map[string]any{"root": root}})
	if !strings.Contains(fmt.Sprint(id.StructuredContent), "organisation") {
		t.Fatalf("identity %+v", id.StructuredContent)
	}
}

func TestIdentityFallsBackToGitConfig(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	exec.Command("git", "-C", root, "config", "user.name", "Cfg Person").Run()
	exec.Command("git", "-C", root, "config", "user.email", "cfg@example.test").Run()
	cs := connectedClient(t)
	id, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_identity",
		Arguments: map[string]any{"root": root}})
	if err != nil || id.IsError {
		t.Fatalf("%v %+v", err, id)
	}
	got := fmt.Sprint(id.StructuredContent)
	if !strings.Contains(got, "cfg@example.test") || !strings.Contains(got, "git config") {
		t.Fatalf("identity %s", got)
	}
}

func TestBlobNamesTheIndexEntry(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	want, _ := exec.Command("git", "-C", root, "rev-parse", ":seed.txt").Output()
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_blob",
		Arguments: map[string]any{"root": root, "path": "seed.txt"}})
	if err != nil || res.IsError {
		t.Fatalf("%v %+v", err, res)
	}
	if !strings.Contains(fmt.Sprint(res.StructuredContent), strings.TrimSpace(string(want))) {
		t.Fatalf("blob %+v want %s", res.StructuredContent, want)
	}
}

func TestStageThenUndoThroughTheTools(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("changed\n"), 0o644)
	cs := connectedClient(t)
	call := func(name string, args map[string]any) {
		t.Helper()
		res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil || res.IsError {
			t.Fatalf("%s: %v %+v", name, err, res)
		}
	}
	call("git_stage", map[string]any{"root": root, "paths": []string{"seed.txt"}})
	out, _ := exec.Command("git", "-C", root, "diff", "--cached", "--name-only").Output()
	if strings.TrimSpace(string(out)) != "seed.txt" {
		t.Fatalf("staged %q", out)
	}
	call("git_unstage", map[string]any{"root": root, "paths": []string{"seed.txt"}})
	out, _ = exec.Command("git", "-C", root, "diff", "--cached", "--name-only").Output()
	if strings.TrimSpace(string(out)) != "" {
		t.Fatalf("still staged %q", out)
	}
}

func TestAWriteOutsideTheProjectIsRefused(t *testing.T) {
	setupProject(t, `"local":{}`, "local")
	cs := connectedClient(t)
	res, _ := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_stage",
		Arguments: map[string]any{"root": t.TempDir(), "paths": []string{"a"}}})
	if !res.IsError {
		t.Fatal("staged in a root outside the project")
	}
}

func TestStatusOnANonRepositoryRootIsAToolError(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_status", Arguments: map[string]any{"root": root}})
	if err != nil || res == nil || !res.IsError {
		t.Fatalf("want a tool error, got %+v %v", res, err)
	}
	var text string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text += tc.Text
		}
	}
	if !strings.Contains(text, "not a git repository") {
		t.Fatalf("text: %q", text)
	}
}
