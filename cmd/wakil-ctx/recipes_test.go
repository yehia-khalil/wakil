package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// setupRecipeProject makes an active project with two repos, api (Laravel with a compose file)
// and web (Vite), and returns the project.json path and the repos' folders.
func setupRecipeProject(t *testing.T) (string, string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755)
	api := filepath.Join(home, "src", "api")
	web := filepath.Join(home, "src", "web")
	files := map[string]string{
		filepath.Join(api, "composer.json"):      `{"require":{"laravel/framework":"^11"}}`,
		filepath.Join(api, "artisan"):            "",
		filepath.Join(api, "docker-compose.yml"): "services:\n  mysql:\n    image: mysql:8\n    ports: ['3306:3306']\n",
		filepath.Join(web, "package.json"):       `{"scripts":{"dev":"vite","build":"vite build"}}`,
		filepath.Join(web, "pnpm-lock.yaml"):     "",
		filepath.Join(web, "vite.config.ts"):     "",
	}
	for p, body := range files {
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	pdir := filepath.Join(home, "proj")
	os.MkdirAll(filepath.Join(pdir, ".wakil"), 0o755)
	pp := filepath.Join(pdir, ".wakil", "project.json")
	body := `{"name":"proj","org":"initech","roots":[{"path":"` + api + `"},{"path":"` + web + `"}],"environments":{}}`
	if err := os.WriteFile(pp, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.SaveRegistry("initech", map[string]wakilcore.ProjectEntry{"proj": {Path: pp}}); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.SetProjectChecked("proj"); err != nil {
		t.Fatal(err)
	}
	return pp, api, web
}

func recipeClient(t *testing.T) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	st, ct := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, st, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "recipe-test", Version: "0"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// callRecipe calls a tool and answers its structured result, or its error text.
func callRecipe(t *testing.T, cs *mcp.ClientSession, name string, args any) (map[string]any, string) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if res.IsError {
		var b strings.Builder
		for _, c := range res.Content {
			if tc, ok := c.(*mcp.TextContent); ok {
				b.WriteString(tc.Text)
			}
		}
		return nil, b.String()
	}
	raw, _ := json.Marshal(res.StructuredContent)
	out := map[string]any{}
	json.Unmarshal(raw, &out)
	return out, ""
}

func TestRecipeDetectAndDraftAll(t *testing.T) {
	setupRecipeProject(t)
	cs := recipeClient(t)
	d, msg := callRecipe(t, cs, "recipe_detect", map[string]any{"repo": "api"})
	if msg != "" || d["kind"] != "laravel" {
		t.Fatalf("detect: %v %s", d, msg)
	}
	if _, msg := callRecipe(t, cs, "recipe_detect", map[string]any{"repo": "nope"}); !strings.Contains(msg, `has no repo named "nope"`) {
		t.Fatalf("unknown repo: %s", msg)
	}
	all, msg := callRecipe(t, cs, "recipe_draft_all", map[string]any{})
	if msg != "" {
		t.Fatal(msg)
	}
	repos := all["repos"].(map[string]any)
	if repos["api"].(map[string]any)["recipe"] != "laravel" || repos["web"].(map[string]any)["recipe"] != "vite-pnpm" {
		t.Fatalf("draft all: %v", repos)
	}
}

func TestRecipeSaveEffectivePlanAndCompose(t *testing.T) {
	pp, api, web := setupRecipeProject(t)
	cs := recipeClient(t)
	_, msg := callRecipe(t, cs, "recipe_save", map[string]any{
		"recipes": map[string]any{
			"laravel": map[string]any{
				"setup":     []string{"composer install"},
				"processes": []map[string]string{{"name": "app", "command": "php artisan serve --port=$WAKIL_PORT"}},
				"env":       map[string]any{"APP_ENV": "local", "STRIPE_SECRET": map[string]string{"secret": "stripe"}},
				"ready":     map[string]string{"url": "http://localhost:$WAKIL_PORT/up"},
			},
		},
		"repos": map[string]any{"api": map[string]any{"recipe": "laravel", "overrides": map[string]any{"env": map[string]any{"APP_ENV": "testing"}}}},
	})
	if msg != "" {
		t.Fatal(msg)
	}
	b, _ := os.ReadFile(pp)
	if !strings.Contains(string(b), `"secret": "stripe"`) || !strings.Contains(string(b), `"recipe": "laravel"`) {
		t.Fatalf("saved:\n%s", b)
	}
	eff, msg := callRecipe(t, cs, "recipe_effective", map[string]any{"repo": "api"})
	if msg != "" {
		t.Fatal(msg)
	}
	env := eff["recipe"].(map[string]any)["env"].(map[string]any)
	from := eff["from"].(map[string]any)
	if env["APP_ENV"] != "testing" || from["env.APP_ENV"] != "repo" || from["env.STRIPE_SECRET"] != "shared" {
		t.Fatalf("effective: %v", eff)
	}

	_, msg = callRecipe(t, cs, "recipe_save", map[string]any{
		"repos": map[string]any{"web": map[string]any{"recipe": "ghost", "overrides": map[string]any{"needs": []string{"web"}}}},
	})
	if !strings.Contains(msg, `repo "web" names recipe "ghost"`) || !strings.Contains(msg, `repo "web" needs itself`) {
		t.Fatalf("invalid save must list every problem: %s", msg)
	}

	plan, msg := callRecipe(t, cs, "recipe_plan", map[string]any{
		"repo": "api", "workspace": "ini-142",
		"checkouts": []map[string]any{{"repo": "api", "path": api, "port": 41200}, {"repo": "web", "path": web}},
	})
	if msg != "" {
		t.Fatal(msg)
	}
	penv := plan["env"].(map[string]any)
	if penv["WAKIL_PORT"] != "41200" || penv["APP_ENV"] != "testing" || plan["secrets"].(map[string]any)["STRIPE_SECRET"] != "wakil:initech:stripe" {
		t.Fatalf("plan env: %v %v", penv, plan["secrets"])
	}
	if plan["ready"].(map[string]any)["url"] != "http://localhost:41200/up" {
		t.Fatalf("ready: %v", plan["ready"])
	}
	if !strings.Contains(plan["files"].([]any)[0].(map[string]any)["content"].(string), `"41200:3306"`) {
		t.Fatalf("override file: %v", plan["files"])
	}
	_, msg = callRecipe(t, cs, "recipe_plan", map[string]any{
		"repo": "api", "workspace": "w",
		"checkouts": []map[string]any{{"repo": "api", "path": "/etc", "port": 41200}},
	})
	if !strings.Contains(msg, "Wakil does not read it (Invariant 6)") {
		t.Fatalf("confinement: %s", msg)
	}

	co, msg := callRecipe(t, cs, "compose_override", map[string]any{"repo": "api", "workspace": "ini-142", "port": 41300})
	if msg != "" || co["projectName"] != "ini-142-api" || !strings.Contains(co["yaml"].(string), `"41300:3306"`) {
		t.Fatalf("compose_override: %v %s", co, msg)
	}
}

func TestReadyWaitAndPortsAllocate(t *testing.T) {
	setupRecipeProject(t)
	cs := recipeClient(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	r, msg := callRecipe(t, cs, "recipe_ready_wait", map[string]any{"url": srv.URL, "timeoutSeconds": 5})
	if msg != "" || r["ready"] != true {
		t.Fatalf("ready: %v %s", r, msg)
	}
	if _, msg := callRecipe(t, cs, "recipe_ready_wait", map[string]any{"url": "http://example.com/"}); !strings.Contains(msg, "is not on this machine") {
		t.Fatalf("remote url: %s", msg)
	}
	r, _ = callRecipe(t, cs, "recipe_ready_wait", map[string]any{"output": "Local:", "text": "  Local: http://localhost:41200"})
	if r["ready"] != true {
		t.Fatalf("output: %v", r)
	}
	if _, msg := callRecipe(t, cs, "recipe_ready_wait", map[string]any{}); msg == "" {
		t.Fatal("nothing to check must be refused")
	}
	a, msg := callRecipe(t, cs, "ports_allocate", map[string]any{"existing": map[string]int{"w/api": 41200}, "want": []string{"w/api", "w/web"}})
	if msg != "" {
		t.Fatal(msg)
	}
	blocks := a["blocks"].(map[string]any)
	if blocks["w/api"] != float64(41200) || blocks["w/web"].(float64) < 41210 {
		t.Fatalf("blocks: %v", blocks)
	}
}
