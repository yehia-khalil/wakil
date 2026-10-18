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

func callFiles(t *testing.T, tool string, args map[string]any) (*mcp.CallToolResult, map[string]any) {
	t.Helper()
	ctx := context.Background()
	st, ct := mcp.NewInMemoryTransports()
	if _, err := newServer().Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "t"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if res.StructuredContent != nil {
		b, _ := json.Marshal(res.StructuredContent)
		_ = json.Unmarshal(b, &out)
	}
	return res, out
}

func TestFilesWriteThenReadThroughTheServer(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "src", "a.go")
	if res, _ := callFiles(t, "files_write", map[string]any{"path": p, "text": "package a\n", "create": true}); res.IsError {
		t.Fatalf("write failed: %+v", res.Content)
	}
	_, out := callFiles(t, "files_read", map[string]any{"path": p})
	if out["text"] != "package a\n" || out["exists"] != true {
		t.Fatalf("read %v", out)
	}
	_, list := callFiles(t, "files_list", map[string]any{"root": pdir})
	if !slices.Contains(toStrings(list["files"]), "src/a.go") {
		t.Fatalf("list %v", list)
	}
}

func TestFilesRefusesAPathOutsideTheProject(t *testing.T) {
	setupProject(t, `"dev":{"databases":[]}`, "")
	res, _ := callFiles(t, "files_read", map[string]any{"path": "/etc/hosts"})
	if !res.IsError {
		t.Fatal("read outside the project was allowed")
	}
	text := res.Content[0].(*mcp.TextContent).Text
	if !strings.Contains(text, "Invariant 6") {
		t.Fatalf("refusal does not name the invariant: %s", text)
	}
}

func toStrings(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}

func TestFilesListDirIsServed(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	if err := os.MkdirAll(filepath.Join(pdir, "vendor", "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	_, out := callFiles(t, "files_list_dir", map[string]any{"root": pdir, "dir": "vendor"})
	entries, _ := out["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("got %v", out)
	}
}

func TestFilesSearchIsServed(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	if err := os.WriteFile(filepath.Join(pdir, "n.txt"), []byte("a needle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, out := callFiles(t, "files_search", map[string]any{"query": "needle"})
	if res.IsError {
		t.Fatalf("search failed: %+v", res.Content[0])
	}
	ms, _ := out["matches"].([]any)
	if len(ms) != 1 {
		t.Fatalf("got %v", out)
	}
}

// 3b-v part 2: files_list takes the active project's heavy folders from its project.json.
func TestFilesListUsesTheProjectsHeavyFolders(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	pp := filepath.Join(pdir, ".wakil", "project.json")
	body := `{"name":"proj","org":"initech","roots":[{"path":"."}],"environments":{"dev":{"databases":[]}},"editor":{"heavyFolders":["storage"]}}`
	if err := os.WriteFile(pp, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", pdir, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	for path, text := range map[string]string{".gitignore": "storage/\nvendor/\n.wakil/\n", "storage/l.log": "l", "vendor/a.php": "v"} {
		p := filepath.Join(pdir, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	res, list := callFiles(t, "files_list", map[string]any{"root": pdir})
	if res.IsError {
		t.Fatalf("files_list: %+v", res.Content)
	}
	if got := strings.Join(toStrings(list["heavy"]), ","); got != ".git,storage" {
		t.Fatalf("heavy %v", got)
	}
	if !slices.Contains(toStrings(list["ignored"]), "vendor/a.php") {
		t.Fatalf("ignored %v; vendor is not on this project's list", list["ignored"])
	}
}

func TestFilesReplaceTextIsServed(t *testing.T) {
	setupProject(t, `"dev":{"databases":[]}`, "")
	res, out := callFiles(t, "files_replace_text", map[string]any{
		"texts": []any{"a foo", "none"}, "query": "foo", "replacement": "bar"})
	if res.IsError {
		t.Fatalf("failed: %+v", res.Content[0])
	}
	results, _ := out["results"].([]any)
	first, _ := results[0].(map[string]any)
	if len(results) != 2 || first["text"] != "a bar" || first["count"] != float64(1) {
		t.Fatalf("got %v", out)
	}
}

func TestFilesReplaceIsServedAndConfined(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "n.txt")
	if err := os.WriteFile(p, []byte("a needle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, out := callFiles(t, "files_replace", map[string]any{"query": "needle", "replacement": "pin"})
	files, _ := out["files"].([]any)
	if res.IsError || len(files) != 1 {
		t.Fatalf("got %v", out)
	}
	if b, _ := os.ReadFile(p); string(b) != "a pin\n" {
		t.Fatalf("disk %q", b)
	}
	res, _ = callFiles(t, "files_replace", map[string]any{"query": "x", "replacement": "y", "only": "/etc/hosts"})
	if !res.IsError || !strings.Contains(res.Content[0].(*mcp.TextContent).Text, "Invariant 6") {
		t.Fatalf("outside the roots: %+v", res.Content)
	}
}

func TestFilesCreateMoveAreServedAndConfined(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "n", "a.go")
	if res, out := callFiles(t, "files_create", map[string]any{"path": p, "kind": "file"}); res.IsError || out["kind"] != "file" {
		t.Fatalf("create %+v %v", res.Content, out)
	}
	q := filepath.Join(pdir, "n", "b.go")
	if res, out := callFiles(t, "files_move", map[string]any{"from": p, "to": q}); res.IsError || out["kind"] != "file" {
		t.Fatalf("move %+v %v", res.Content, out)
	}
	res, _ := callFiles(t, "files_move", map[string]any{"from": q, "to": "/tmp/escaped.go"})
	if !res.IsError || !strings.Contains(res.Content[0].(*mcp.TextContent).Text, "Invariant 6") {
		t.Fatalf("move outside not refused by the invariant: %+v", res.Content)
	}
	res, _ = callFiles(t, "files_trash", map[string]any{"path": pdir})
	if !res.IsError {
		t.Fatal("trashed the root")
	}
}

// 3b-vii: from reaches ReadFileFrom through the tool, so a growing log reads only what was added.
func TestFilesReadFromThroughTheTool(t *testing.T) {
	pdir := setupProject(t, `"dev":{"databases":[]}`, "")
	p := filepath.Join(pdir, "laravel.log")
	if err := os.WriteFile(p, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, out := callFiles(t, "files_read", map[string]any{"path": p, "from": 4})
	if res.IsError || out["text"] != "two\n" || out["end"] != float64(8) {
		t.Fatalf("got %+v %v", out, res.Content)
	}
}
