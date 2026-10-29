package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Running a plan (workspaces piece 2, the Swift half's Go side): the window runs processes in
// terminals, but the one-shot steps, the files a plan writes, copy and clone, and Try run here, so
// their output comes back whole and a cancelled call stops them.

// RunShell is the shell one-shot steps run in: the operator's login shell, so PATH is what their
// terminal has after its profile (Homebrew, mise shims). Overridable for tests.
var RunShell = func() string {
	if s := os.Getenv("SHELL"); s != "" && filepath.IsAbs(s) {
		return s
	}
	return "/bin/zsh"
}

// PrepareResult says what PrepareRun did.
type PrepareResult struct {
	Wrote  []string `json:"wrote"`
	Copied []string `json:"copied"`
	Cloned []string `json:"cloned"`
	// EnvFile is the .env written, when the recipe opts in.
	EnvFile string `json:"envFile,omitempty"`
}

// PrepareRun gets a checkout ready for a plan: the plan's files written (each, when asked, kept
// out of git through the checkout's info/exclude), on a first run the copy and clone steps from
// Main's folder (never over a file the checkout has), and the .env lines when the recipe opts in,
// secrets included. secretValues maps each of the plan's secret variables to its value.
func PrepareRun(plan RunPlan, firstRun bool, secretValues map[string]string) (PrepareResult, error) {
	out := PrepareResult{Wrote: []string{}, Copied: []string{}, Cloned: []string{}}
	if plan.Dir == "" {
		return out, UserError("the plan names no folder to run in")
	}
	for _, f := range plan.Files {
		if err := safeRel(f.Path); err != nil {
			return out, err
		}
		dest := filepath.Join(plan.Dir, f.Path)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return out, UserError(fmt.Sprintf("cannot make the folder for %s: %v", dest, err))
		}
		if err := os.WriteFile(dest, []byte(f.Content), 0o644); err != nil {
			return out, UserError(fmt.Sprintf("cannot write %s: %v", dest, err))
		}
		if f.GitExclude {
			if err := gitExclude(plan.Dir, f.Path); err != nil {
				return out, err
			}
		}
		out.Wrote = append(out.Wrote, f.Path)
	}
	if firstRun {
		for _, s := range plan.Steps {
			if s.Phase != PhaseCopy && s.Phase != PhaseClone {
				continue
			}
			done, err := copyFromMain(s.From, s.Dir, s.Paths, s.Phase == PhaseClone)
			if err != nil {
				return out, err
			}
			if s.Phase == PhaseClone {
				out.Cloned = append(out.Cloned, done...)
			} else {
				out.Copied = append(out.Copied, done...)
			}
		}
	}
	if plan.EnvFile != nil {
		set := map[string]string{}
		for _, k := range plan.EnvFile.Keys {
			if v, ok := plan.Env[k]; ok {
				set[k] = v
			} else if v, ok := secretValues[k]; ok {
				set[k] = v
			}
		}
		existing, err := os.ReadFile(plan.EnvFile.Path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return out, UserError(fmt.Sprintf("cannot read %s: %v", plan.EnvFile.Path, err))
		}
		if err := os.WriteFile(plan.EnvFile.Path, []byte(MergeDotEnv(string(existing), set)), 0o600); err != nil {
			return out, UserError(fmt.Sprintf("cannot write %s: %v", plan.EnvFile.Path, err))
		}
		out.EnvFile = plan.EnvFile.Path
	}
	return out, nil
}

func safeRel(p string) error {
	if p == "" || filepath.IsAbs(p) || strings.HasPrefix(filepath.Clean(p), "..") {
		return UserError(fmt.Sprintf("plan file %q must be a path inside the checkout", p))
	}
	return nil
}

// gitExclude adds rel to the checkout's info/exclude (a worktree's is its common dir's) once.
func gitExclude(dir, rel string) error {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--git-path", "info/exclude")
	b, err := cmd.Output()
	if err != nil {
		return nil // not a git folder: nothing to keep it out of
	}
	path := strings.TrimSpace(string(b))
	if !filepath.IsAbs(path) {
		path = filepath.Join(dir, path)
	}
	line := "/" + filepath.ToSlash(rel)
	existing, _ := os.ReadFile(path)
	for _, l := range strings.Split(string(existing), "\n") {
		if strings.TrimSpace(l) == line {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return UserError(fmt.Sprintf("cannot keep %s out of git: %v", rel, err))
	}
	body := string(existing)
	if body != "" && !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	if err := os.WriteFile(path, []byte(body+line+"\n"), 0o644); err != nil {
		return UserError(fmt.Sprintf("cannot keep %s out of git: %v", rel, err))
	}
	return nil
}

// copyFromMain copies (or clones, copy-on-write) each match of globs in from into dir, keeping
// its relative path; a path the checkout already has is left alone. Answers what it brought.
func copyFromMain(from, dir string, globs []string, clone bool) ([]string, error) {
	if from == "" || dir == "" || filepath.Clean(from) == filepath.Clean(dir) {
		return nil, nil
	}
	var done []string
	for _, g := range globs {
		if err := safeRel(g); err != nil {
			return done, err
		}
		matches, err := filepath.Glob(filepath.Join(from, g))
		if err != nil {
			return done, UserError(fmt.Sprintf("copy pattern %q is not a valid glob: %v", g, err))
		}
		sort.Strings(matches)
		for _, m := range matches {
			rel, _ := filepath.Rel(from, m)
			dest := filepath.Join(dir, rel)
			if _, err := os.Lstat(dest); err == nil {
				continue
			}
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				return done, UserError(fmt.Sprintf("cannot make the folder for %s: %v", dest, err))
			}
			args := []string{"-R", m, dest}
			if clone {
				args = []string{"-Rc", m, dest}
			}
			var errb bytes.Buffer
			cmd := exec.Command("/bin/cp", args...)
			cmd.Stderr = &errb
			if err := cmd.Run(); err != nil && clone {
				// Not on APFS: a plain copy, never a symlink (call 6).
				errb.Reset()
				cmd = exec.Command("/bin/cp", "-R", m, dest)
				cmd.Stderr = &errb
				err = cmd.Run()
				if err != nil {
					return done, UserError(fmt.Sprintf("cannot clone %s into the checkout: %s", rel, strings.TrimSpace(errb.String())))
				}
			} else if err != nil {
				return done, UserError(fmt.Sprintf("cannot copy %s into the checkout: %s", rel, strings.TrimSpace(errb.String())))
			}
			done = append(done, rel)
		}
	}
	return done, nil
}

// StepResult is one step run headless.
type StepResult struct {
	Phase    string  `json:"phase"`
	Name     string  `json:"name,omitempty"`
	Command  string  `json:"command,omitempty"`
	OK       bool    `json:"ok"`
	ExitCode int     `json:"exitCode"`
	Output   string  `json:"output"`
	Seconds  float64 `json:"seconds"`
	Detail   string  `json:"detail,omitempty"`
}

// envList is the process environment with env laid over it.
func envList(env map[string]string) []string {
	base := os.Environ()
	out := make([]string, 0, len(base)+len(env))
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		if _, over := env[k]; !over {
			out = append(out, kv)
		}
	}
	for _, k := range sortedKeys(env) {
		out = append(out, k+"="+env[k])
	}
	return out
}

func shellCommand(ctx context.Context, dir, command string, env map[string]string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, RunShell(), "-l", "-c", command)
	cmd.Dir = dir
	cmd.Env = envList(env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	return cmd
}

// ExecStep runs one command to its end in dir: combined output whole, exit code, and why it
// stopped when it was cancelled or ran out of time (the whole process group goes with it).
func ExecStep(ctx context.Context, dir string, env map[string]string, command string, timeout time.Duration) StepResult {
	start := time.Now()
	res := StepResult{Command: command}
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	var buf bytes.Buffer
	cmd := shellCommand(ctx, dir, command, env)
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	res.Seconds = time.Since(start).Seconds()
	res.Output = buf.String()
	switch {
	case ctx.Err() == context.DeadlineExceeded:
		res.ExitCode = -1
		res.Detail = fmt.Sprintf("%s did not finish within %s and was stopped.", command, timeout)
	case ctx.Err() != nil:
		res.ExitCode = -1
		res.Detail = fmt.Sprintf("%s was cancelled.", command)
	case err != nil:
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			res.ExitCode = exit.ExitCode()
			res.Detail = fmt.Sprintf("%s exited with %d.", command, res.ExitCode)
		} else {
			res.ExitCode = -1
			res.Detail = fmt.Sprintf("%s could not start: %v", command, err)
		}
	default:
		res.OK = true
	}
	return res
}

// TryResult is Try's report: every step in order, passed or failed with its output whole.
type TryResult struct {
	Passed bool         `json:"passed"`
	Steps  []StepResult `json:"steps"`
	Ready  *ReadyResult `json:"ready,omitempty"`
}

// lockedBuffer collects a background process's output.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// TryOptions tunes Try for tests.
type TryOptions struct {
	StepTimeout   time.Duration
	PollInterval  time.Duration
	SecretValues  map[string]string
	ReadyURLCheck func(ctx context.Context, url string, timeout time.Duration) ReadyResult
}

// TryRecipe proves a plan in a throwaway checkout (decision 13's Try): prepare as a first run,
// services, setup, the processes started headless, the ready check, then the processes stopped
// and teardown run. A need is reported, not started: Try proves this repo's own recipe.
func TryRecipe(ctx context.Context, plan RunPlan, opt TryOptions) TryResult {
	if opt.StepTimeout == 0 {
		opt.StepTimeout = 15 * time.Minute
	}
	if opt.PollInterval == 0 {
		opt.PollInterval = 500 * time.Millisecond
	}
	env := map[string]string{}
	for k, v := range plan.Env {
		env[k] = v
	}
	for k, v := range opt.SecretValues {
		env[k] = v
	}
	out := TryResult{Steps: []StepResult{}}
	fail := func(s StepResult) TryResult {
		out.Steps = append(out.Steps, s)
		return out
	}
	prep, err := PrepareRun(plan, true, opt.SecretValues)
	if err != nil {
		return fail(StepResult{Phase: "prepare", Detail: err.Error()})
	}
	out.Steps = append(out.Steps, StepResult{Phase: "prepare", OK: true, Output: prepareSummary(prep)})
	for _, s := range plan.Steps {
		switch s.Phase {
		case PhaseNeed:
			out.Steps = append(out.Steps, StepResult{Phase: PhaseNeed, Name: s.Target, OK: true,
				Detail: fmt.Sprintf("Try does not start %s; Run starts it first.", s.Target)})
		case PhaseService, PhaseSetup:
			r := ExecStep(ctx, plan.Dir, env, s.Command, opt.StepTimeout)
			r.Phase = s.Phase
			out.Steps = append(out.Steps, r)
			if !r.OK {
				teardown(ctx, plan, env, opt, &out)
				return out
			}
		}
	}
	// The processes, headless, each in its own process group.
	type running struct {
		name string
		cmd  *exec.Cmd
		out  *lockedBuffer
		done chan error
	}
	var procs []running
	procCtx, stopProcs := context.WithCancel(ctx)
	defer stopProcs()
	for _, s := range plan.Steps {
		if s.Phase != PhaseProcess {
			continue
		}
		buf := &lockedBuffer{}
		cmd := shellCommand(procCtx, plan.Dir, s.Command, env)
		cmd.Stdout, cmd.Stderr = buf, buf
		if err := cmd.Start(); err != nil {
			out.Steps = append(out.Steps, StepResult{Phase: PhaseProcess, Name: s.Name, Command: s.Command,
				ExitCode: -1, Detail: fmt.Sprintf("%s could not start: %v", s.Command, err)})
			stopProcs()
			teardown(ctx, plan, env, opt, &out)
			return out
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		procs = append(procs, running{name: s.Name, cmd: cmd, out: buf, done: done})
	}
	ready := tryReady(ctx, plan, opt, func() (string, string) {
		var all strings.Builder
		for _, p := range procs {
			select {
			case err := <-p.done:
				p.done <- err
				return all.String(), fmt.Sprintf("process %s ended before the app was ready", p.name)
			default:
			}
			all.WriteString(p.out.String())
		}
		return all.String(), ""
	})
	stopProcs()
	allOK := ready == nil || ready.Ready
	for _, p := range procs {
		<-p.done
		out.Steps = append(out.Steps, StepResult{Phase: PhaseProcess, Name: p.name, Command: commandOf(plan, p.name),
			OK: allOK, Output: p.out.String()})
	}
	out.Ready = ready
	teardown(ctx, plan, env, opt, &out)
	out.Passed = allOK && ctx.Err() == nil
	for _, s := range out.Steps {
		if !s.OK {
			out.Passed = false
		}
	}
	return out
}

func commandOf(plan RunPlan, name string) string {
	for _, s := range plan.Steps {
		if s.Phase == PhaseProcess && s.Name == name {
			return s.Command
		}
	}
	return ""
}

// tryReady waits for the plan's ready check; nil when the recipe has none (then the processes
// are only required to keep running for a moment).
func tryReady(ctx context.Context, plan RunPlan, opt TryOptions, output func() (string, string)) *ReadyResult {
	if plan.Ready == nil {
		select {
		case <-ctx.Done():
			return &ReadyResult{false, "Try was cancelled"}
		case <-time.After(2 * opt.PollInterval):
		}
		if _, ended := output(); ended != "" {
			return &ReadyResult{false, ended}
		}
		return nil
	}
	timeout := time.Duration(plan.Ready.TimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = DefaultReadyTimeoutSeconds * time.Second
	}
	if plan.Ready.URL != "" {
		check := opt.ReadyURLCheck
		if check == nil {
			check = func(ctx context.Context, url string, timeout time.Duration) ReadyResult {
				return WaitReadyURL(ctx, nil, url, timeout, opt.PollInterval)
			}
		}
		r := check(ctx, plan.Ready.URL, timeout)
		return &r
	}
	deadline := time.Now().Add(timeout)
	for {
		text, ended := output()
		ok, err := MatchReadyOutput(plan.Ready.Output, text)
		if err != nil {
			return &ReadyResult{false, err.Error()}
		}
		if ok {
			return &ReadyResult{true, fmt.Sprintf("the output shows %s", plan.Ready.Output)}
		}
		if ended != "" {
			return &ReadyResult{false, ended}
		}
		if time.Now().After(deadline) {
			return &ReadyResult{false, fmt.Sprintf("the output did not show %s within %s", plan.Ready.Output, timeout)}
		}
		select {
		case <-ctx.Done():
			return &ReadyResult{false, "Try was cancelled"}
		case <-time.After(opt.PollInterval):
		}
	}
}

func teardown(ctx context.Context, plan RunPlan, env map[string]string, opt TryOptions, out *TryResult) {
	// Teardown runs even after a cancel, so containers do not outlive Try.
	tctx := context.WithoutCancel(ctx)
	for _, s := range plan.Teardown {
		r := ExecStep(tctx, plan.Dir, env, s.Command, opt.StepTimeout)
		r.Phase = PhaseTeardown
		out.Steps = append(out.Steps, r)
	}
}

func prepareSummary(p PrepareResult) string {
	var parts []string
	if len(p.Wrote) > 0 {
		parts = append(parts, "wrote "+strings.Join(p.Wrote, ", "))
	}
	if len(p.Copied) > 0 {
		parts = append(parts, "copied "+strings.Join(p.Copied, ", "))
	}
	if len(p.Cloned) > 0 {
		parts = append(parts, "cloned "+strings.Join(p.Cloned, ", "))
	}
	if p.EnvFile != "" {
		parts = append(parts, "wrote "+p.EnvFile)
	}
	if len(parts) == 0 {
		return "nothing to copy or write"
	}
	return strings.Join(parts, "; ")
}

// ReadPlanSecrets reads each of a plan's secrets from the Keychain by its service name
// (wakil:<org>:<ref>); a missing one is refused naming the variable and how to store it.
func ReadPlanSecrets(org string, secrets map[string]string) (map[string]string, error) {
	out := map[string]string{}
	prefix := "wakil:" + org + ":"
	var problems []string
	for _, k := range sortedKeys(secrets) {
		svc := secrets[k]
		if !strings.HasPrefix(svc, prefix) {
			problems = append(problems, fmt.Sprintf("secret %s names %s, which is not this organisation's", k, svc))
			continue
		}
		v, err := SecretGetFor(org, strings.TrimPrefix(svc, prefix))
		if err != nil {
			if errors.Is(err, ErrSecretNotFound) {
				problems = append(problems, fmt.Sprintf("secret %s has no value in the Keychain yet; set it in the project's Running settings", k))
			} else {
				problems = append(problems, fmt.Sprintf("secret %s cannot be read: %v", k, err))
			}
			continue
		}
		out[k] = v
	}
	if len(problems) > 0 {
		return nil, UserError(strings.Join(problems, "; ") + ".")
	}
	return out, nil
}

// RunSecretRef is the Keychain ref a Running settings secret is kept under: derived, never typed.
func RunSecretRef(project, owner, variable string) string {
	return "run:" + project + ":" + owner + ":" + variable
}
