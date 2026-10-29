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
	"time"

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

func toolNames(t *testing.T, cs *mcp.ClientSession) string {
	t.Helper()
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range res.Tools {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}

// Invariant 2: the agent's own copy of wakil-git (agentMCPConfigJSON) never sets the flag, so it
// has the reads alone; a write reaches git only through the registry's editor_changes_* actions.
func TestWithoutTheWritesFlagTheToolListIsTheReadsAlone(t *testing.T) {
	t.Setenv(gitWritesEnv, "")
	if got := toolNames(t, connectedClient(t)); got != "git_blame,git_blob,git_branches,git_diff,git_file_history,git_identity,git_origin,git_show,git_stashes,git_status" {
		t.Fatalf("tools %s", got)
	}
}

func TestToolListIsTheReadsAndTheWrites(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
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
	want := []string{"git_amend", "git_blame", "git_blob", "git_branch_delete", "git_branch_rename", "git_branches", "git_clone",
		"git_commit", "git_diff", "git_discard", "git_fetch", "git_file_history", "git_identity", "git_origin", "git_publish", "git_pull", "git_push",
		"git_show", "git_stage", "git_stage_hunk", "git_stash", "git_stash_apply", "git_stash_drop",
		"git_stash_drop_all", "git_stash_pop", "git_stash_undo_apply", "git_stashes", "git_status", "git_switch", "git_sync",
		"git_undo_commit", "git_unstage"}
	want = append(want, "git_abort", "git_continue", "git_merge", "git_rebase", "git_resolve", "git_skip")
	want = append(want, "workspaces_read", "workspaces_write", "git_worktree_add", "git_worktree_remove",
		"git_worktree_list", "git_worktree_prune", "git_snapshot_apply", "git_take_from_main")
	sort.Strings(want)
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("tools %v", names)
	}
}

func TestCommitThroughTheToolUsesTheOrganisationsIdentity(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
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
	t.Setenv(gitWritesEnv, "1")
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
	t.Setenv(gitWritesEnv, "1")
	setupProject(t, `"local":{}`, "local")
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_stage",
		Arguments: map[string]any{"root": t.TempDir(), "paths": []string{"a"}}})
	if err != nil || res == nil {
		t.Fatalf("call: %+v %v", res, err)
	}
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

func toolText(res *mcp.CallToolResult) string {
	var text string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text += tc.Text
		}
	}
	return text
}

// Invariant 4: an unreadable org.json is not "no identity" — committing as git config's would be
// committing as someone else.
func TestAnUnreadableOrganisationRecordRefusesTheCommitAndTheIdentity(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	home := os.Getenv("HOME")
	if err := os.WriteFile(filepath.Join(home, ".wakil", "orgs", "initech", "org.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	before, _ := exec.Command("git", "-C", root, "rev-parse", "HEAD").Output()
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("changed\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_commit",
		Arguments: map[string]any{"root": root, "message": "m", "all": true}})
	if err != nil || res == nil || !res.IsError || !strings.Contains(toolText(res), "org.json") {
		t.Fatalf("want a tool error naming org.json, got %+v %v", res, err)
	}
	if after, _ := exec.Command("git", "-C", root, "rev-parse", "HEAD").Output(); string(after) != string(before) {
		t.Fatal("a commit landed")
	}
	id, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_identity",
		Arguments: map[string]any{"root": root}})
	if err != nil || id == nil || !id.IsError || !strings.Contains(toolText(id), "org.json") {
		t.Fatalf("want a tool error naming org.json, got %+v %v", id, err)
	}
}

// from names where the email came from, since the hint shows the email.
func TestIdentityWithOnlyTheOrganisationsNameSaysTheEmailIsGitConfigs(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	exec.Command("git", "-C", root, "config", "user.email", "cfg@example.test").Run()
	name := "Org Person"
	if err := wakilcore.UpdateOrg("initech", wakilcore.OrgPatch{GitName: &name}); err != nil {
		t.Fatal(err)
	}
	cs := connectedClient(t)
	id, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_identity",
		Arguments: map[string]any{"root": root}})
	if err != nil || id.IsError {
		t.Fatalf("%v %+v", err, id)
	}
	b, _ := json.Marshal(id.StructuredContent)
	if got := string(b); !strings.Contains(got, `"email":"cfg@example.test"`) || !strings.Contains(got, `"from":"git config"`) ||
		!strings.Contains(got, `"name":"Org Person"`) {
		t.Fatalf("identity %s", got)
	}
	email := "org@example.test"
	empty := ""
	if err := wakilcore.UpdateOrg("initech", wakilcore.OrgPatch{GitName: &empty, GitEmail: &email}); err != nil {
		t.Fatal(err)
	}
	id, _ = cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_identity",
		Arguments: map[string]any{"root": root}})
	if b, _ := json.Marshal(id.StructuredContent); !strings.Contains(string(b), `"from":"organisation"`) {
		t.Fatalf("identity %s", b)
	}
}

// Review I4: an org switch stops wakil-git with SIGTERM. Remote work is cancelled through its
// context, so its own cleanup (abort a pull, remove a clone's folder) runs before the process exits.
func TestShutdownCancelsRemoteWork(t *testing.T) {
	sd, stop := context.WithCancel(context.Background())
	defer stop()
	prev := shutdown
	shutdown = sd
	defer func() { shutdown = prev }()

	ctx, done := remoteContext(context.Background())
	waited := make(chan struct{})
	go func() { remoteWork.Wait(); close(waited) }()
	stop()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("shutdown did not cancel the remote work")
	}
	select {
	case <-waited:
		t.Fatal("the exit did not wait for the work's cleanup")
	case <-time.After(50 * time.Millisecond):
	}
	done()
	<-waited
}

// 3a-iv: a switch git refuses comes back as the paths in the way, not an error, so the picker can
// offer Stash and Switch or Bring Them Along.
func TestSwitchToolReportsBlockedPaths(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	g := func(args ...string) {
		t.Helper()
		c := exec.Command("git", append([]string{"-C", root, "-c", "user.name=t", "-c", "user.email=t@x"}, args...)...)
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	g("switch", "-q", "-c", "other")
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("other\n"), 0o644)
	g("commit", "-qam", "other")
	g("switch", "-q", "-")
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("mine\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_switch",
		Arguments: map[string]any{"root": root, "branch": "other"}})
	if err != nil || res.IsError {
		t.Fatalf("call: %v %+v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(raw), `"blocked":["seed.txt"]`) || strings.Contains(string(raw), `"switched":true`) {
		t.Fatalf("result %s", raw)
	}
}

func TestGitFileHistoryTool(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_file_history", Arguments: map[string]any{"root": root, "path": "seed.txt"}})
	if err != nil || res.IsError {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), `"subject":"seed"`) || !strings.Contains(string(b), `"path":"seed.txt"`) {
		t.Fatalf("%s", b)
	}
}

func TestGitBlameTool(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "git_blame", Arguments: map[string]any{"root": root, "path": "seed.txt", "text": "new\nseed\n"}})
	if err != nil || res.IsError {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(b), `"author":"t"`) || !strings.Contains(string(b), `"id":"0000000000000000000000000000000000000000"`) {
		t.Fatalf("%s", b)
	}
}

// gitIn runs git in dir, isolated from the machine's config.
func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	c := exec.Command("git", args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// conflictedRepo leaves main and other disagreeing about a.txt.
func conflictedRepo(t *testing.T) string {
	t.Helper()
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	write := func(s string) { os.WriteFile(filepath.Join(root, "a.txt"), []byte(s), 0o644) }
	write("base\n")
	gitIn(t, root, "add", "a.txt")
	gitIn(t, root, "commit", "-m", "base")
	gitIn(t, root, "switch", "-c", "other")
	write("theirs\n")
	gitIn(t, root, "commit", "-am", "other")
	gitIn(t, root, "switch", "main")
	write("ours\n")
	gitIn(t, root, "commit", "-am", "main")
	return root
}

func callTool(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// A conflict stop is a result the caller reads, not a tool error.
func TestMergeToolStopsOnConflicts(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := conflictedRepo(t)
	cs := connectedClient(t)
	res := callTool(t, cs, "git_merge", map[string]any{"root": root, "branch": "other"})
	if res.IsError {
		t.Fatalf("a conflict stop is not an error: %s", toolText(res))
	}
	var r wakilcore.GitMergeResult
	if err := json.Unmarshal([]byte(toolText(res)), &r); err != nil {
		t.Fatal(err)
	}
	if r.Done || len(r.Conflicts) != 1 || r.Conflicts[0] != "a.txt" {
		t.Fatalf("result %+v", r)
	}

	// Resolve, continue, and the merge lands.
	if res := callTool(t, cs, "git_resolve", map[string]any{"root": root, "path": "a.txt", "take": "incoming"}); res.IsError {
		t.Fatalf("resolve: %s", toolText(res))
	}
	res = callTool(t, cs, "git_continue", map[string]any{"root": root})
	if res.IsError || !strings.Contains(toolText(res), `"done":true`) {
		t.Fatalf("continue: %s", toolText(res))
	}
}

func TestAbortToolReturnsTheResult(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := conflictedRepo(t)
	cs := connectedClient(t)
	callTool(t, cs, "git_merge", map[string]any{"root": root, "branch": "other"})
	res := callTool(t, cs, "git_abort", map[string]any{"root": root})
	if res.IsError || !strings.Contains(toolText(res), `"done":true`) {
		t.Fatalf("abort: %s", toolText(res))
	}
	st := callTool(t, cs, "git_status", map[string]any{"root": root})
	if strings.Contains(toolText(st), `"conflicts"`) {
		t.Fatalf("still conflicted: %s", toolText(st))
	}
}

func TestStashApplyToolReturnsTheClash(t *testing.T) {
	t.Setenv(gitWritesEnv, "1")
	root := conflictedRepo(t)
	os.WriteFile(filepath.Join(root, "a.txt"), []byte("stashed\n"), 0o644)
	gitIn(t, root, "stash", "push", "-m", "mine")
	os.WriteFile(filepath.Join(root, "a.txt"), []byte("moved on\n"), 0o644)
	gitIn(t, root, "commit", "-am", "moved on")
	cs := connectedClient(t)
	list := callTool(t, cs, "git_stashes", map[string]any{"root": root})
	var sl struct{ Stashes []wakilcore.GitStash }
	if err := json.Unmarshal([]byte(toolText(list)), &sl); err != nil || len(sl.Stashes) != 1 {
		t.Fatalf("%v %s", err, toolText(list))
	}
	res := callTool(t, cs, "git_stash_apply", map[string]any{"root": root, "index": 0, "id": sl.Stashes[0].ID})
	if res.IsError {
		t.Fatalf("apply: %s", toolText(res))
	}
	var out struct {
		Note  string
		Clash *wakilcore.GitStashClash
	}
	if err := json.Unmarshal([]byte(toolText(res)), &out); err != nil || out.Clash == nil || out.Clash.ID == "" {
		t.Fatalf("no clash: %v %s", err, toolText(res))
	}
	undo := callTool(t, cs, "git_stash_undo_apply", map[string]any{"root": root, "clash": out.Clash})
	if undo.IsError {
		t.Fatalf("undo: %s", toolText(undo))
	}
}
