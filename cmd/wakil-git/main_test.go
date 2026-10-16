package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
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

func TestToolListIsExactlyTheThreeReads(t *testing.T) {
	cs := connectedClient(t)
	tools, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tl := range tools.Tools {
		names = append(names, tl.Name)
	}
	slices.Sort(names)
	if !slices.Equal(names, []string{"git_diff", "git_show", "git_status"}) {
		t.Fatalf("%v", names)
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
