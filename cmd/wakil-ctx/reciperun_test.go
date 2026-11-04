package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	// One step of a phase, by its command (a card names the step it is on); a command the recipe
	// does not have runs nothing.
	one, msg := callRecipe(t, cs, "recipe_run_steps", with(map[string]any{"phases": []string{"setup"}, "commands": []string{"echo never"}}))
	if msg != "" || one["ok"] != true || len(one["steps"].([]any)) != 1 || one["steps"].([]any)[0].(map[string]any)["command"] != "echo never" {
		t.Fatalf("one step: %v %s", one, msg)
	}
	if _, msg := callRecipe(t, cs, "recipe_run_steps", with(map[string]any{"phases": []string{"setup"}, "commands": []string{"rm -rf ~"}})); !strings.Contains(msg, "is not a step of") {
		t.Fatalf("a command the recipe does not have: %s", msg)
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

// A plan with no secrets answers secretEnv as an empty object: the tool's output schema says object, and a
// nil map marshals as null, which the SDK refuses ("has type null, want object") — the card's ▶ said so.
func TestRecipePrepareResultSecretEnvIsAnObjectWithNoSecrets(t *testing.T) {
	data, err := json.Marshal(newRecipePrepareResult(nil, wakilcore.PrepareResult{}, nil))
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	json.Unmarshal(data, &out)
	if _, ok := out["secretEnv"].(map[string]any); !ok {
		t.Fatalf("secretEnv is %#v, want an object", out["secretEnv"])
	}
}

// Try in steps the window follows (the walk: one line for minutes): recipe_try_start answers a job
// at once, recipe_try_status answers every step's state as it runs and the result once finished,
// recipe_try_cancel stops the running step (Rule 4) with teardown still run; an unknown job is named.
func TestRecipeTryStartStatusAndCancel(t *testing.T) {
	_, api, web := setupRecipeProject(t)
	old := wakilcore.RunShell
	wakilcore.RunShell = func() string { return "/bin/sh" }
	t.Cleanup(func() { wakilcore.RunShell = old })
	cs := recipeClient(t)
	if _, msg := callRecipe(t, cs, "recipe_save", map[string]any{
		"recipes": map[string]any{"vite": map[string]any{
			"setup":     []string{"echo one", "echo two; sleep 30"},
			"processes": []map[string]string{{"name": "dev", "command": "echo 'Local: ready'; sleep 30"}},
			"ready":     map[string]any{"output": "Local:", "timeoutSeconds": 5},
			"teardown":  []string{"echo down"},
		}},
		"repos": map[string]any{"web": map[string]any{"recipe": "vite"}},
	}); msg != "" {
		t.Fatal(msg)
	}
	checkout := filepath.Join(os.Getenv("HOME"), ".wakil", "orgs", "initech", "workspaces", "proj", "w", "web")
	os.MkdirAll(checkout, 0o755)
	started, msg := callRecipe(t, cs, "recipe_try_start", map[string]any{"repo": "web", "workspace": "w",
		"checkouts": []map[string]any{{"repo": "web", "path": checkout, "port": 41200}, {"repo": "api", "path": api}}})
	if msg != "" || started["job"] == "" {
		t.Fatalf("start: %v %s", started, msg)
	}
	job := started["job"].(string)
	var running map[string]any
	for i := 0; i < 300 && running == nil; i++ {
		st, msg := callRecipe(t, cs, "recipe_try_status", map[string]any{"job": job})
		if msg != "" {
			t.Fatal(msg)
		}
		steps := st["steps"].([]any)
		if s := steps[2].(map[string]any); s["state"] == "running" && s["lastLine"] == "two" {
			running = st
		}
		time.Sleep(10 * time.Millisecond)
	}
	if running == nil {
		t.Fatal("the second setup step was never seen running with its line")
	}
	if s := running["steps"].([]any)[1].(map[string]any); s["state"] != "done" || s["command"] != "echo one" {
		t.Errorf("the first setup step: %v", s)
	}
	if _, msg := callRecipe(t, cs, "recipe_try_cancel", map[string]any{"job": job}); msg != "" {
		t.Fatal(msg)
	}
	var final map[string]any
	for i := 0; i < 300 && final == nil; i++ {
		st, _ := callRecipe(t, cs, "recipe_try_status", map[string]any{"job": job})
		if st["finished"] == true {
			final = st
		}
		time.Sleep(10 * time.Millisecond)
	}
	if final == nil || final["result"].(map[string]any)["passed"] != false {
		t.Fatalf("after cancel: %v", final)
	}
	steps := final["steps"].([]any)
	if s := steps[2].(map[string]any); s["state"] != "failed" || !strings.Contains(s["detail"].(string), "cancelled") {
		t.Errorf("the cancelled step: %v", s)
	}
	if s := steps[len(steps)-1].(map[string]any); s["phase"] != "teardown" || s["state"] != "done" {
		t.Errorf("teardown after cancel: %v", s)
	}
	if _, msg := callRecipe(t, cs, "recipe_try_status", map[string]any{"job": "nope"}); !strings.Contains(msg, "no Try nope") {
		t.Errorf("unknown job: %s", msg)
	}
	_ = web
}
