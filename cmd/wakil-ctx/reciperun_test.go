package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

func TestRecipePrepareRunStepsAndTry(t *testing.T) {
	_, api, web := setupRecipeProject(t)
	old := wakilcore.RunShell
	wakilcore.RunShell = func() string { return "/bin/sh" }
	t.Cleanup(func() { wakilcore.RunShell = old })
	cs := recipeClient(t)
	os.WriteFile(filepath.Join(web, ".env"), []byte("MAIN=1\n"), 0o644)
	_, msg := callRecipe(t, cs, "recipe_save", map[string]any{
		"recipes": map[string]any{"vite": map[string]any{
			"copy":      []string{".env"},
			"services":  []string{"echo services on $WAKIL_PORT"},
			"setup":     []string{"echo installed > setup.txt", "exit 4", "echo never"},
			"build":     "echo built",
			"processes": []map[string]string{{"name": "dev", "command": "echo 'Local: ready'; sleep 30"}},
			"ready":     map[string]any{"output": "Local:", "timeoutSeconds": 5},
			"teardown":  []string{"echo down"},
		}},
		"repos": map[string]any{"web": map[string]any{"recipe": "vite"}},
	})
	if msg != "" {
		t.Fatal(msg)
	}
	list, msg := callRecipe(t, cs, "recipe_list", map[string]any{})
	if msg != "" || list["recipes"].(map[string]any)["vite"] == nil || len(list["repos"].([]any)) != 2 {
		t.Fatalf("list: %v %s", list, msg)
	}
	webRow := list["repos"].([]any)[1].(map[string]any)
	if webRow["repo"] != "web" || webRow["recipe"] != "vite" || webRow["effective"].(map[string]any)["recipeName"] != "vite" {
		t.Fatalf("web row: %v", webRow)
	}
	checkout := filepath.Join(os.Getenv("HOME"), ".wakil", "orgs", "initech", "workspaces", "proj", "w", "web")
	os.MkdirAll(checkout, 0o755)
	args := map[string]any{"repo": "web", "workspace": "w",
		"checkouts": []map[string]any{{"repo": "web", "path": checkout, "port": 41200}, {"repo": "api", "path": api}}}
	with := func(extra map[string]any) map[string]any {
		out := map[string]any{}
		for k, v := range args {
			out[k] = v
		}
		for k, v := range extra {
			out[k] = v
		}
		return out
	}

	prep, msg := callRecipe(t, cs, "recipe_prepare", with(map[string]any{"firstRun": true}))
	if msg != "" {
		t.Fatal(msg)
	}
	if copied := prep["prepared"].(map[string]any)["copied"].([]any); len(copied) != 1 || copied[0] != ".env" {
		t.Fatalf("prepared: %v", prep["prepared"])
	}
	if prep["plan"].(map[string]any)["dir"] != checkout {
		t.Fatalf("plan: %v", prep["plan"])
	}

	steps, msg := callRecipe(t, cs, "recipe_run_steps", with(map[string]any{"phases": []string{"service", "setup"}}))
	if msg != "" {
		t.Fatal(msg)
	}
	ran := steps["steps"].([]any)
	if steps["ok"] != false || len(ran) != 3 || !strings.Contains(ran[0].(map[string]any)["output"].(string), "services on 41200") ||
		ran[2].(map[string]any)["exitCode"].(float64) != 4 {
		t.Fatalf("steps: %v", steps)
	}
	if _, err := os.Stat(filepath.Join(checkout, "setup.txt")); err != nil {
		t.Fatal("setup did not run in the checkout")
	}
	built, msg := callRecipe(t, cs, "recipe_run_steps", with(map[string]any{"phases": []string{"build"}}))
	if msg != "" || built["ok"] != true || !strings.Contains(built["steps"].([]any)[0].(map[string]any)["output"].(string), "built") {
		t.Fatalf("build: %v %s", built, msg)
	}
	if _, msg := callRecipe(t, cs, "recipe_run_steps", with(map[string]any{"phases": []string{"process"}})); !strings.Contains(msg, "not a one-shot phase") {
		t.Fatalf("process phase: %s", msg)
	}

	// Try fails at setup (exit 4) and still tears down.
	try, msg := callRecipe(t, cs, "recipe_try", args)
	if msg != "" {
		t.Fatal(msg)
	}
	tried := try["steps"].([]any)
	if try["passed"] != false || tried[len(tried)-1].(map[string]any)["phase"] != "teardown" {
		t.Fatalf("try: %v", try)
	}
}

func TestRecipeSecretSetNeedsEveryPart(t *testing.T) {
	setupRecipeProject(t)
	cs := recipeClient(t)
	if _, msg := callRecipe(t, cs, "recipe_secret_set", map[string]any{"project": "proj", "owner": "", "variable": "X", "value": "v"}); !strings.Contains(msg, "give the project") {
		t.Fatalf("%s", msg)
	}
	if _, msg := callRecipe(t, cs, "recipe_secret_set", map[string]any{"project": "proj", "owner": "web", "variable": "X", "value": " "}); !strings.Contains(msg, "is empty") {
		t.Fatalf("%s", msg)
	}
}
