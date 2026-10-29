package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPrepareRunWritesFilesCopiesAndClonesOnceNeverOverwriting(t *testing.T) {
	main, dir := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(main, ".env"), []byte("A=main\n"), 0o644)
	os.WriteFile(filepath.Join(main, ".env.testing"), []byte("T=1\n"), 0o644)
	os.MkdirAll(filepath.Join(main, "vendor", "pkg"), 0o755)
	os.WriteFile(filepath.Join(main, "vendor", "pkg", "x.php"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(dir, ".env.testing"), []byte("T=mine\n"), 0o644)
	plan := RunPlan{
		Dir:   dir,
		Env:   map[string]string{"APP_PORT": "41200"},
		Files: []PlannedFile{{Path: ".wakil/compose.ports.yml", Content: "services: {}\n"}},
		Steps: []PlanStep{
			{Phase: PhaseCopy, Paths: []string{".env*"}, From: main, Dir: dir},
			{Phase: PhaseClone, Paths: []string{"vendor", "node_modules"}, From: main, Dir: dir},
		},
		EnvFile: &EnvFilePlan{Path: filepath.Join(dir, ".env"), Keys: []string{"APP_PORT", "TOKEN"}},
	}
	res, err := PrepareRun(plan, true, map[string]string{"TOKEN": "s3cret"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(res.Copied, ",") != ".env" || strings.Join(res.Cloned, ",") != "vendor" {
		t.Fatalf("copied %v cloned %v", res.Copied, res.Cloned)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".env.testing")); string(b) != "T=mine\n" {
		t.Fatalf("overwrote the checkout's own file: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "vendor", "pkg", "x.php")); string(b) != "x" {
		t.Fatalf("clone missing: %q", b)
	}
	env, _ := os.ReadFile(filepath.Join(dir, ".env"))
	if !strings.HasPrefix(string(env), "A=main\n") || !strings.Contains(string(env), "APP_PORT=41200") || !strings.Contains(string(env), "TOKEN=s3cret") {
		t.Fatalf(".env: %q", env)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".wakil", "compose.ports.yml")); string(b) != "services: {}\n" {
		t.Fatalf("file: %q", b)
	}
	// Not a first run: no copy.
	os.Remove(filepath.Join(dir, "vendor", "pkg", "x.php"))
	res, _ = PrepareRun(plan, false, nil)
	if len(res.Cloned) != 0 {
		t.Fatalf("cloned again: %v", res.Cloned)
	}
}

func TestPrepareRunRefusesAFileOutsideTheCheckout(t *testing.T) {
	_, err := PrepareRun(RunPlan{Dir: t.TempDir(), Files: []PlannedFile{{Path: "../x"}}}, false, nil)
	if err == nil || !strings.Contains(err.Error(), "inside the checkout") {
		t.Fatalf("err %v", err)
	}
}

func useSh(t *testing.T) {
	old := RunShell
	RunShell = func() string { return "/bin/sh" }
	t.Cleanup(func() { RunShell = old })
}

func TestExecStepReportsOutputExitCodeTimeoutAndCancel(t *testing.T) {
	useSh(t)
	dir := t.TempDir()
	r := ExecStep(context.Background(), dir, map[string]string{"WAKIL_PORT": "41200"}, "echo port $WAKIL_PORT; exit 3", 0)
	if r.OK || r.ExitCode != 3 || !strings.Contains(r.Output, "port 41200") || !strings.Contains(r.Detail, "exited with 3") {
		t.Fatalf("%+v", r)
	}
	r = ExecStep(context.Background(), dir, nil, "sleep 5", 200*time.Millisecond)
	if r.OK || !strings.Contains(r.Detail, "did not finish within") {
		t.Fatalf("%+v", r)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(100 * time.Millisecond); cancel() }()
	r = ExecStep(ctx, dir, nil, "sleep 5", 0)
	if r.OK || !strings.Contains(r.Detail, "cancelled") || r.Seconds > 4 {
		t.Fatalf("%+v", r)
	}
}

func TestTryRecipeRunsEveryStepWaitsForTheReadyLineThenStopsAndTearsDown(t *testing.T) {
	useSh(t)
	dir := t.TempDir()
	plan := RunPlan{
		Dir: dir, Env: map[string]string{"WAKIL_PORT": "41200"}, Files: []PlannedFile{},
		Steps: []PlanStep{
			{Phase: PhaseNeed, Target: "core-db"},
			{Phase: PhaseService, Command: "echo services up"},
			{Phase: PhaseSetup, Command: "echo installed > setup.txt"},
			{Phase: PhaseProcess, Name: "app", Command: "echo Local: http://localhost:$WAKIL_PORT; sleep 30"},
		},
		Ready:    &ReadyPlan{Output: "Local:", TimeoutSeconds: 5},
		Teardown: []PlanStep{{Phase: PhaseTeardown, Command: "echo down > down.txt"}},
	}
	res := TryRecipe(context.Background(), plan, TryOptions{PollInterval: 20 * time.Millisecond})
	if !res.Passed || res.Ready == nil || !res.Ready.Ready {
		t.Fatalf("%+v", res)
	}
	var phases []string
	for _, s := range res.Steps {
		phases = append(phases, s.Phase)
	}
	if strings.Join(phases, ",") != "prepare,need,service,setup,process,teardown" {
		t.Fatalf("phases %v", phases)
	}
	if !strings.Contains(res.Steps[4].Output, "Local: http://localhost:41200") {
		t.Fatalf("process output %q", res.Steps[4].Output)
	}
	if _, err := os.Stat(filepath.Join(dir, "down.txt")); err != nil {
		t.Fatal("teardown did not run")
	}
}

func TestTryRecipeStopsAtAFailedSetupAndStillTearsDown(t *testing.T) {
	useSh(t)
	dir := t.TempDir()
	plan := RunPlan{
		Dir: dir, Env: map[string]string{},
		Steps: []PlanStep{
			{Phase: PhaseSetup, Command: "echo composer failed >&2; exit 1"},
			{Phase: PhaseProcess, Name: "app", Command: "sleep 30"},
		},
		Teardown: []PlanStep{{Phase: PhaseTeardown, Command: "true"}},
	}
	res := TryRecipe(context.Background(), plan, TryOptions{PollInterval: 20 * time.Millisecond})
	if res.Passed || len(res.Steps) != 3 || res.Steps[1].OK || !strings.Contains(res.Steps[1].Output, "composer failed") || res.Steps[2].Phase != PhaseTeardown {
		t.Fatalf("%+v", res)
	}
}

func TestTryRecipeFailsWhenAProcessEndsBeforeReady(t *testing.T) {
	useSh(t)
	plan := RunPlan{
		Dir: t.TempDir(), Env: map[string]string{},
		Steps: []PlanStep{{Phase: PhaseProcess, Name: "app", Command: "echo boom; exit 2"}},
		Ready: &ReadyPlan{Output: "never", TimeoutSeconds: 5},
	}
	res := TryRecipe(context.Background(), plan, TryOptions{PollInterval: 20 * time.Millisecond})
	if res.Passed || res.Ready == nil || !strings.Contains(res.Ready.Detail, "process app ended") {
		t.Fatalf("%+v", res)
	}
}

func TestRunSecretRefIsDerived(t *testing.T) {
	if got := RunSecretRef("estate", "api", "STRIPE_SECRET"); got != "run:estate:api:STRIPE_SECRET" {
		t.Fatal(got)
	}
}
