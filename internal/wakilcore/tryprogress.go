package wakilcore

import (
	"io"
	"strings"
	"sync"
	"time"
)

// Try's progress (the walk, piece 2: Try read one line for minutes while it copied, prepared,
// ran services and setup, started the processes and waited for ready). A TryTracker lists every
// step of a plan before any runs and follows each as TryRecipe runs it — to come, running (with
// its output so far), then done or failed with its seconds — so the window can draw the list
// live (recipe_try_start / recipe_try_status).

// A step's state.
const (
	TryStepToCome  = "to come"
	TryStepRunning = "running"
	TryStepDone    = "done"
	TryStepFailed  = "failed"
)

// PhaseReady is the ready check's row in Try's progress.
const PhaseReady = "ready"

// TryStep is one row of Try's progress. Command is the step's command (a process's, the ready
// check's URL or line); Seconds is the step's time, or so far while it runs; LastLine is the last
// line of its output, for the running row.
type TryStep struct {
	Phase     string  `json:"phase"`
	Name      string  `json:"name,omitempty"`
	Command   string  `json:"command,omitempty"`
	State     string  `json:"state"`
	Seconds   float64 `json:"seconds"`
	Output    string  `json:"output"`
	LastLine  string  `json:"lastLine,omitempty"`
	Detail    string  `json:"detail,omitempty"`
	ExitCode  int     `json:"exitCode"`
	StartedAt int64   `json:"startedAt,omitempty"`
}

// TryProgress is a tracker's state at one moment; Result is set once Try finished.
type TryProgress struct {
	Steps    []TryStep  `json:"steps"`
	Finished bool       `json:"finished"`
	Result   *TryResult `json:"result,omitempty"`
}

// TryTracker follows one Try. Its methods are safe on a nil tracker (no progress wanted).
type TryTracker struct {
	mu       sync.Mutex
	steps    []TryStep
	outs     []*lockedBuffer
	started  []time.Time
	finished bool
	result   *TryResult
	scrub    func(string) string
}

func (t *TryTracker) useScrub(f func(string) string) {
	if t == nil || f == nil {
		return
	}
	t.mu.Lock()
	t.scrub = f
	t.mu.Unlock()
}

// NewTryTracker lists plan's steps in the order Try runs them: prepare, the services and setup
// steps, build, each process started, the ready check, teardown. A need is not listed: Try
// reports it and starts nothing.
func NewTryTracker(plan RunPlan) *TryTracker {
	t := &TryTracker{}
	add := func(s TryStep) {
		s.State = TryStepToCome
		t.steps = append(t.steps, s)
		t.outs = append(t.outs, &lockedBuffer{})
		t.started = append(t.started, time.Time{})
	}
	add(TryStep{Phase: "prepare"})
	for _, s := range plan.Steps {
		if s.Phase == PhaseService || s.Phase == PhaseSetup {
			add(TryStep{Phase: s.Phase, Command: s.Command})
		}
	}
	if plan.Build != nil {
		add(TryStep{Phase: PhaseBuild, Command: plan.Build.Command})
	}
	for _, s := range plan.Steps {
		if s.Phase == PhaseProcess {
			add(TryStep{Phase: PhaseProcess, Name: s.Name, Command: s.Command})
		}
	}
	if plan.Ready != nil {
		add(TryStep{Phase: PhaseReady, Command: readyWhat(plan.Ready)})
	}
	for _, s := range plan.Teardown {
		add(TryStep{Phase: PhaseTeardown, Command: s.Command})
	}
	return t
}

func readyWhat(r *ReadyPlan) string {
	if r.URL != "" {
		return r.URL
	}
	return r.Output
}

// begin marks the first row still to come with this phase, name and command running; -1 when
// none is listed (a need).
func (t *TryTracker) begin(phase, name, command string) int {
	if t == nil {
		return -1
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for i, s := range t.steps {
		if s.State == TryStepToCome && s.Phase == phase && s.Name == name && (command == "" || s.Command == command) {
			t.steps[i].State = TryStepRunning
			t.started[i] = time.Now()
			t.steps[i].StartedAt = t.started[i].UnixMilli()
			return i
		}
	}
	return -1
}

// writer is where row i's output goes as it is written; io.Discard for no row.
func (t *TryTracker) writer(i int) io.Writer {
	if t == nil || i < 0 {
		return io.Discard
	}
	return t.outs[i]
}

// end closes row i: done or failed, with its output whole when given (else what was written).
func (t *TryTracker) end(i int, r StepResult) {
	if t == nil || i < 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	s := &t.steps[i]
	s.State = TryStepDone
	if !r.OK {
		s.State = TryStepFailed
	}
	s.Seconds = r.Seconds
	if s.Seconds == 0 && !t.started[i].IsZero() {
		s.Seconds = time.Since(t.started[i]).Seconds()
	}
	s.Output = r.Output
	if s.Output == "" {
		s.Output = t.outs[i].String()
	}
	s.Detail, s.ExitCode = r.Detail, r.ExitCode
}

func (t *TryTracker) finish(res TryResult) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.finished = true
	r := res
	r.Steps = append([]StepResult(nil), res.Steps...)
	for i := range r.Steps {
		if t.scrub != nil {
			r.Steps[i].Output = t.scrub(r.Steps[i].Output)
		}
	}
	t.result = &r
}

// Snapshot is the progress now: a running row carries its output so far, its last line and its
// seconds so far.
func (t *TryTracker) Snapshot() TryProgress {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := TryProgress{Steps: make([]TryStep, len(t.steps)), Finished: t.finished, Result: t.result}
	for i, s := range t.steps {
		if s.State == TryStepRunning {
			s.Output = t.outs[i].String()
			s.Seconds = time.Since(t.started[i]).Seconds()
		}
		if t.scrub != nil {
			s.Output = t.scrub(s.Output)
		}
		s.LastLine = lastLine(s.Output)
		out.Steps[i] = s
	}
	return out
}

func lastLine(text string) string {
	lines := strings.Split(strings.TrimRight(text, "\r\n "), "\n")
	return strings.TrimSpace(strings.TrimRight(lines[len(lines)-1], "\r"))
}
