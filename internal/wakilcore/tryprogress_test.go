package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Try's progress, step by step (the walk: Try read "Trying … in a throwaway workspace…" for
// minutes): every step is listed before any runs, each goes to come → running → done or failed
// with its seconds, a running step's output grows as it is written, and the ready check is a row.
func TestTryProgressListsEveryStepAndFollowsEachAsItRuns(t *testing.T) {
	useSh(t)
	plan := RunPlan{
		Dir: t.TempDir(), Env: map[string]string{"WAKIL_PORT": "41200"},
		Steps: []PlanStep{
			{Phase: PhaseService, Command: "echo services up"},
			{Phase: PhaseSetup, Command: "echo one; sleep 0.4; echo two"},
			{Phase: PhaseSetup, Command: "echo installed"},
			{Phase: PhaseProcess, Name: "app", Command: "echo Local: http://localhost:$WAKIL_PORT; sleep 30"},
		},
		Build:    &PlanStep{Phase: PhaseBuild, Command: "echo built"},
		Ready:    &ReadyPlan{Output: "Local:", TimeoutSeconds: 5},
		Teardown: []PlanStep{{Phase: PhaseTeardown, Command: "true"}},
	}
	tracker := NewTryTracker(plan)
	first := tracker.Snapshot()
	var listed []string
	for _, s := range first.Steps {
		listed = append(listed, s.Phase+":"+s.State)
	}
	if strings.Join(listed, ",") != "prepare:to come,service:to come,setup:to come,setup:to come,build:to come,process:to come,ready:to come,teardown:to come" {
		t.Fatalf("listed before running: %v", listed)
	}
	done := make(chan TryResult, 1)
	go func() {
		done <- TryRecipe(context.Background(), plan, TryOptions{PollInterval: 20 * time.Millisecond, Progress: tracker})
	}()
	// The second setup step is seen running, with its first line and not yet its last.
	var seen bool
	for i := 0; i < 200 && !seen; i++ {
		s := tracker.Snapshot().Steps[2]
		if s.State == TryStepRunning && strings.Contains(s.Output, "one") && !strings.Contains(s.Output, "two") && s.LastLine == "one" {
			seen = true
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !seen {
		t.Fatalf("the running step's output was not followed: %+v", tracker.Snapshot().Steps[2])
	}
	res := <-done
	if !res.Passed {
		t.Fatalf("%+v", res)
	}
	last := tracker.Snapshot()
	if !last.Finished {
		t.Fatal("not finished")
	}
	for _, s := range last.Steps {
		if s.State != TryStepDone {
			t.Errorf("%s %s: %s", s.Phase, s.Command, s.State)
		}
	}
	if last.Steps[2].Seconds < 0.3 || !strings.Contains(last.Steps[6].Detail, "Local:") {
		t.Errorf("seconds %v, ready %q", last.Steps[2].Seconds, last.Steps[6].Detail)
	}
}

// A failed step is failed, its output whole; what never ran stays to come, and teardown still runs.
func TestTryProgressMarksTheFailedStepAndLeavesTheRestToCome(t *testing.T) {
	useSh(t)
	plan := RunPlan{
		Dir: t.TempDir(), Env: map[string]string{},
		Steps: []PlanStep{
			{Phase: PhaseSetup, Command: "echo composer failed >&2; exit 1"},
			{Phase: PhaseProcess, Name: "app", Command: "sleep 30"},
		},
		Teardown: []PlanStep{{Phase: PhaseTeardown, Command: "true"}},
	}
	tracker := NewTryTracker(plan)
	TryRecipe(context.Background(), plan, TryOptions{PollInterval: 20 * time.Millisecond, Progress: tracker})
	s := tracker.Snapshot()
	if s.Steps[1].State != TryStepFailed || !strings.Contains(s.Steps[1].Output, "composer failed") {
		t.Fatalf("setup: %+v", s.Steps[1])
	}
	if s.Steps[2].State != TryStepToCome {
		t.Errorf("the process never started: %+v", s.Steps[2])
	}
	if s.Steps[3].State != TryStepDone || !s.Finished {
		t.Errorf("teardown: %+v", s.Steps[3])
	}
}

// A process marked afterReady starts only once the ready check passed (the walk: a Sail queue
// failed because laravel.test was not up yet); its row comes after ready's.
func TestTryStartsAnAfterReadyProcessOnlyOnceTheAppIsReady(t *testing.T) {
	useSh(t)
	dir := t.TempDir()
	plan := RunPlan{
		Dir: dir, Env: map[string]string{},
		Steps: []PlanStep{
			{Phase: PhaseProcess, Name: "queue", Command: "test -f app.up && echo ok > queue.ok; sleep 30", AfterReady: true},
			{Phase: PhaseProcess, Name: "app", Command: "sleep 0.3; touch app.up; echo Local: up; sleep 30"},
		},
		Ready: &ReadyPlan{Output: "Local:", TimeoutSeconds: 5},
	}
	tracker := NewTryTracker(plan)
	var order []string
	for _, s := range tracker.Snapshot().Steps {
		order = append(order, s.Phase+":"+s.Name)
	}
	if strings.Join(order, ",") != "prepare:,process:app,ready:,process:queue" {
		t.Fatalf("rows: %v", order)
	}
	res := TryRecipe(context.Background(), plan, TryOptions{PollInterval: 20 * time.Millisecond, Progress: tracker})
	if !res.Passed {
		t.Fatalf("%+v", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "queue.ok")); err != nil {
		t.Fatal("the afterReady process started before the app was up")
	}
}
