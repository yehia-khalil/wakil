package wakilcore

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The run plan (workspaces piece 2): an effective recipe turned into ordered steps the window runs
// in terminals — needs, copy and clone, services, setup, processes, then the ready check — with
// the environment every step gets and the files to write first. Commands are not expanded: the
// terminal's environment carries the values, and secrets are named by their Keychain service,
// never read here.

// Plan phases, in run order.
const (
	PhaseNeed     = "need"
	PhaseCopy     = "copy"
	PhaseClone    = "clone"
	PhaseService  = "service"
	PhaseSetup    = "setup"
	PhaseProcess  = "process"
	PhaseBuild    = "build"
	PhaseTeardown = "teardown"
)

// Once values: how often a step runs.
const (
	OnceWorkspace = "workspace"
	OnceCheckout  = "checkout"
)

// DefaultReadyTimeoutSeconds is how long a ready check waits when the recipe does not say.
const DefaultReadyTimeoutSeconds = 120

// PlanStep is one step of a run plan.
type PlanStep struct {
	Phase       string   `json:"phase"`
	Name        string   `json:"name,omitempty"`
	Command     string   `json:"command,omitempty"`
	Dir         string   `json:"dir,omitempty"`
	LongRunning bool     `json:"longRunning"`
	Once        string   `json:"once,omitempty"`
	Target      string   `json:"target,omitempty"`
	TargetKind  string   `json:"targetKind,omitempty"`
	Paths       []string `json:"paths,omitempty"`
	From        string   `json:"from,omitempty"`
}

// PlannedFile is a file to write (relative to the plan's dir) before any step runs.
type PlannedFile struct {
	Path       string `json:"path"`
	Content    string `json:"content"`
	GitExclude bool   `json:"gitExclude"`
}

// EnvFilePlan says which variables also go into the checkout's .env.
type EnvFilePlan struct {
	Path string   `json:"path"`
	Keys []string `json:"keys"`
}

// ReadyPlan is the expanded ready check.
type ReadyPlan struct {
	URL            string `json:"url,omitempty"`
	Output         string `json:"output,omitempty"`
	TimeoutSeconds int    `json:"timeoutSeconds"`
}

// RunPlan is everything the window needs to run a repo (or a shared service) in a workspace.
type RunPlan struct {
	Repo     string            `json:"repo"`
	Recipe   string            `json:"recipe,omitempty"`
	Dir      string            `json:"dir"`
	Env      map[string]string `json:"env"`
	Secrets  map[string]string `json:"secrets"`
	EnvFile  *EnvFilePlan      `json:"envFile,omitempty"`
	Files    []PlannedFile     `json:"files"`
	Steps    []PlanStep        `json:"steps"`
	Build    *PlanStep         `json:"build,omitempty"`
	Ready    *ReadyPlan        `json:"ready,omitempty"`
	Teardown []PlanStep        `json:"teardown"`
	Warnings []string          `json:"warnings"`
}

// PlanInput is where a plan runs.
type PlanInput struct {
	// Org names the Keychain services of secrets.
	Org string `json:"org"`
	// Workspace is the workspace slug.
	Workspace string `json:"workspace"`
	// Repo is a repo of the project, or the name of a shared-service recipe.
	Repo string `json:"repo"`
	// MainDir is Main's folder of the repo, where copy and clone read from.
	MainDir string `json:"mainDir"`
	// Checkouts is every repo of the workspace with its folder and port block.
	Checkouts []CheckoutPorts `json:"checkouts"`
}

// BuildRunPlan builds the plan for one repo or shared service.
func BuildRunPlan(p Project, in PlanInput) (RunPlan, error) {
	var recipe Recipe
	runRepo, recipeName := in.Repo, ""
	if _, isRepo := FindRoot(p, in.Repo); isRepo {
		eff, err := EffectiveRecipe(p, in.Repo)
		if err != nil {
			return RunPlan{}, err
		}
		if eff.DoesntRun {
			return RunPlan{}, UserError(fmt.Sprintf("%s is marked doesn't run, so there is nothing to start.", in.Repo))
		}
		if eff.RecipeName == "" && len(eff.From) == 0 {
			return RunPlan{}, UserError(fmt.Sprintf("%s has no recipe yet; draft one in the project's Running settings.", in.Repo))
		}
		recipe, recipeName = eff.Recipe, eff.RecipeName
	} else if r, ok := p.Recipes[in.Repo]; ok && IsSharedService(r) {
		if err := ValidateRecipes(p); err != nil {
			return RunPlan{}, err
		}
		if r.In == nil {
			return RunPlan{}, UserError(fmt.Sprintf("shared service %s names no repo to run in; set its in.", in.Repo))
		}
		recipe, recipeName, runRepo = r, in.Repo, *r.In
	} else {
		return RunPlan{}, UserError(fmt.Sprintf("project %q has no repo or shared service named %q.", p.Name, in.Repo))
	}

	wenv, err := WakilEnv(RunContext{Workspace: in.Workspace, Repo: runRepo, Checkouts: in.Checkouts})
	if err != nil {
		return RunPlan{}, err
	}
	dir := wenv["WAKIL_DIR"]
	plan := RunPlan{
		Repo: in.Repo, Recipe: recipeName, Dir: dir, Env: wenv, Secrets: map[string]string{},
		Files: []PlannedFile{}, Steps: []PlanStep{}, Teardown: []PlanStep{}, Warnings: []string{},
	}
	for _, k := range sortedKeys(recipe.Ports) {
		v, err := ExpandWakil(recipe.Ports[k], wenv)
		if err != nil {
			return RunPlan{}, UserError(fmt.Sprintf("%s's port variable %s: %s", in.Repo, k, err.Error()))
		}
		plan.Env[k] = v
	}
	for _, k := range sortedKeys(recipe.Env) {
		e := recipe.Env[k]
		if e.Secret != "" {
			svc, err := keychainService(in.Org, e.Secret)
			if err != nil {
				return RunPlan{}, err
			}
			plan.Secrets[k] = svc
			continue
		}
		v, err := ExpandWakil(e.Value, wenv)
		if err != nil {
			return RunPlan{}, UserError(fmt.Sprintf("%s's env variable %s: %s", in.Repo, k, err.Error()))
		}
		plan.Env[k] = v
	}
	if recipe.AlsoWriteEnvFile != nil && *recipe.AlsoWriteEnvFile {
		keys := append(sortedKeys(recipe.Env), sortedKeys(recipe.Ports)...)
		sort.Strings(keys)
		plan.EnvFile = &EnvFilePlan{Path: filepath.Join(dir, ".env"), Keys: keys}
	}

	// Compose: the generated override, and COMPOSE_FILE naming it after the repo's own files.
	if file := FindComposeFile(dir); file != "" {
		b, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil {
			return RunPlan{}, UserError(fmt.Sprintf("cannot read %s: %v", filepath.Join(dir, file), err))
		}
		facts, err := ParseCompose(b, file)
		if err != nil {
			return RunPlan{}, err
		}
		port, _ := strconv.Atoi(wenv["WAKIL_PORT"])
		res, err := ComposeOverride(facts, in.Workspace, runRepo, port, ReservedOffsets(recipe.Ports))
		if err != nil {
			return RunPlan{}, err
		}
		if res.CannotRunTwice != "" {
			plan.Warnings = append(plan.Warnings, res.CannotRunTwice)
		}
		if res.YAML != "" {
			files := []string{file}
			for _, o := range []string{"compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml"} {
				if _, err := os.Stat(filepath.Join(dir, o)); err == nil {
					files = append(files, o)
					break
				}
			}
			files = append(files, ComposeOverridePath)
			plan.Env["COMPOSE_FILE"] = strings.Join(files, ":")
			plan.Files = append(plan.Files, PlannedFile{Path: ComposeOverridePath, Content: res.YAML, GitExclude: true})
		}
	}

	for _, need := range recipe.Needs {
		kind := "repo"
		if _, ok := p.Recipes[need]; ok {
			if _, isRepo := FindRoot(p, need); !isRepo {
				kind = "service"
			}
		}
		plan.Steps = append(plan.Steps, PlanStep{Phase: PhaseNeed, Target: need, TargetKind: kind, Once: OnceWorkspace})
	}
	if len(recipe.Copy) > 0 {
		plan.Steps = append(plan.Steps, PlanStep{Phase: PhaseCopy, Paths: recipe.Copy, From: in.MainDir, Dir: dir, Once: OnceCheckout})
	}
	if len(recipe.Clone) > 0 {
		plan.Steps = append(plan.Steps, PlanStep{Phase: PhaseClone, Paths: recipe.Clone, From: in.MainDir, Dir: dir, Once: OnceCheckout})
	}
	for _, c := range recipe.Services {
		plan.Steps = append(plan.Steps, PlanStep{Phase: PhaseService, Command: c, Dir: dir, Once: OnceWorkspace})
	}
	for _, c := range recipe.Setup {
		plan.Steps = append(plan.Steps, PlanStep{Phase: PhaseSetup, Command: c, Dir: dir, Once: OnceCheckout})
	}
	for _, proc := range recipe.Processes {
		plan.Steps = append(plan.Steps, PlanStep{Phase: PhaseProcess, Name: proc.Name, Command: proc.Command, Dir: dir, LongRunning: true})
	}
	if recipe.Build != nil && strings.TrimSpace(*recipe.Build) != "" {
		plan.Build = &PlanStep{Phase: PhaseBuild, Command: *recipe.Build, Dir: dir}
	}
	for _, c := range recipe.Teardown {
		plan.Teardown = append(plan.Teardown, PlanStep{Phase: PhaseTeardown, Command: c, Dir: dir})
	}
	if recipe.Ready != nil {
		r := ReadyPlan{Output: recipe.Ready.Output, TimeoutSeconds: recipe.Ready.TimeoutSeconds}
		if r.TimeoutSeconds == 0 {
			r.TimeoutSeconds = DefaultReadyTimeoutSeconds
		}
		if recipe.Ready.URL != "" {
			u, err := ExpandWakil(recipe.Ready.URL, plan.Env)
			if err != nil {
				return RunPlan{}, UserError(fmt.Sprintf("%s's ready url: %s", in.Repo, err.Error()))
			}
			r.URL = u
		}
		plan.Ready = &r
	}
	return plan, nil
}

// MergeDotEnv sets each variable in an .env body: an existing line keeps its place with the new
// value; a new one is added at the end under a Wakil comment. Other lines are kept as they are.
func MergeDotEnv(existing string, set map[string]string) string {
	lines := strings.Split(existing, "\n")
	if existing == "" {
		lines = nil
	}
	done := map[string]bool{}
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		prefix := ""
		if strings.HasPrefix(trimmed, "export ") {
			prefix, trimmed = "export ", strings.TrimPrefix(trimmed, "export ")
		}
		k, _, ok := strings.Cut(trimmed, "=")
		k = strings.TrimSpace(k)
		if v, want := set[k]; ok && want {
			lines[i] = prefix + k + "=" + dotEnvQuote(v)
			done[k] = true
		}
	}
	var added []string
	for _, k := range sortedKeys(set) {
		if !done[k] {
			added = append(added, k+"="+dotEnvQuote(set[k]))
		}
	}
	out := strings.Join(lines, "\n")
	if len(added) > 0 {
		if out != "" && !strings.HasSuffix(out, "\n") {
			out += "\n"
		}
		if out != "" {
			out += "\n"
		}
		out += "# Added by Wakil for this workspace\n" + strings.Join(added, "\n") + "\n"
	}
	return out
}

var dotEnvPlain = regexp.MustCompile(`^[A-Za-z0-9_./:@+,=%-]*$`)

func dotEnvQuote(v string) string {
	if dotEnvPlain.MatchString(v) {
		return v
	}
	return strconv.Quote(v)
}

// ReadyResult says whether the app came up.
type ReadyResult struct {
	Ready  bool   `json:"ready"`
	Detail string `json:"detail"`
}

// MatchReadyOutput says whether text holds the ready line: a substring, or /a regexp/.
func MatchReadyOutput(pattern, text string) (bool, error) {
	if isRegexpPattern(pattern) {
		re, err := regexp.Compile(pattern[1 : len(pattern)-1])
		if err != nil {
			return false, UserError(fmt.Sprintf("ready output %s is not a valid regular expression: %v", pattern, err))
		}
		return re.MatchString(text), nil
	}
	return strings.Contains(text, pattern), nil
}

// WaitReadyURL polls url until it answers 200–399, the timeout passes or ctx is cancelled.
func WaitReadyURL(ctx context.Context, client *http.Client, url string, timeout, interval time.Duration) ReadyResult {
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	last := "nothing answered"
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return ReadyResult{false, fmt.Sprintf("ready url %s cannot be requested: %v", url, err)}
		}
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 400 {
				return ReadyResult{true, fmt.Sprintf("%s answered %d", url, resp.StatusCode)}
			}
			last = fmt.Sprintf("it last answered %d", resp.StatusCode)
		} else if ctx.Err() == nil {
			last = "it last failed: " + err.Error()
		}
		select {
		case <-ctx.Done():
			if ctx.Err() == context.DeadlineExceeded {
				return ReadyResult{false, fmt.Sprintf("%s did not answer within %s; %s.", url, timeout, last)}
			}
			return ReadyResult{false, "the ready check was cancelled"}
		case <-time.After(interval):
		}
	}
}
