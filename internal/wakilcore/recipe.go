package wakilcore

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Recipe is how a repo runs (workspaces piece 2, decisions 13–15): written once under a project's
// `recipes` and named by each repo that uses it, or stored on a repo as its overrides.
//
// **One type for both.** A repo's overrides are a Recipe whose absent fields inherit, so absence
// must survive a round trip: lists carry `omitzero` (nil is absent, `[]` is "none, here"), scalars
// are pointers. A shared service is a recipe with only `services` (and `teardown`, `in`): it runs
// once per workspace for every repo that `needs` it.
type Recipe struct {
	// Needs names other repos of the project, or shared-service recipes, started first.
	Needs []string `json:"needs,omitzero"`
	// Ports maps the repo's own port variables to an expression over Wakil's ($WAKIL_PORT…), so a
	// compose file that already reads a variable is not rewritten.
	Ports map[string]string `json:"ports,omitempty"`
	// Env is set for every command of the repo; values may use $WAKIL_*. A secret is a Keychain
	// ref, never a value.
	Env map[string]EnvValue `json:"env,omitempty"`
	// AlsoWriteEnvFile adds Env's lines to the worktree's own .env (never Main's).
	AlsoWriteEnvFile *bool `json:"alsoWriteEnvFile,omitempty"`
	// Copy is ignored files copied from Main's folder (gitignore globs).
	Copy []string `json:"copy,omitzero"`
	// Clone is heavy ignored folders cloned copy-on-write.
	Clone []string `json:"clone,omitzero"`
	// Services are commands started once per workspace before the app.
	Services []string `json:"services,omitzero"`
	// Setup runs once in a new worktree.
	Setup []string `json:"setup,omitzero"`
	// Processes are the app: named long-running commands, each in its own terminal. Ordered.
	Processes []Process `json:"processes,omitzero"`
	// Build is a one-shot build.
	Build *string `json:"build,omitempty"`
	// Ready says how Wakil knows the app is up.
	Ready *Ready `json:"ready,omitempty"`
	// Teardown runs when services stop or the workspace is archived.
	Teardown []string `json:"teardown,omitzero"`
	// In names the repo whose folder a shared service's commands run in.
	In *string `json:"in,omitempty"`
	// Notes says, per field key, where a value came from ("README § Getting started"). Written by
	// a draft and kept; merged per key like Ports.
	Notes map[string]string `json:"notes,omitempty"`
}

// Process is one named long-running command of a recipe. In a repo's overrides an empty Command
// removes the shared process of that name.
type Process struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

// Ready is a URL that answers (200–399) or a line in the output: a substring, or /a regexp/.
type Ready struct {
	URL            string `json:"url,omitempty"`
	Output         string `json:"output,omitempty"`
	TimeoutSeconds int    `json:"timeoutSeconds,omitempty"`
}

// EnvValue is one env variable: a plain value, or a secret named by its Keychain ref. On disk a
// value is a JSON string and a secret is {"secret": "<ref>"}, stored in the Keychain as
// wakil:<org>:<ref> and filled in at run time.
type EnvValue struct {
	Value  string
	Secret string
}

func (e EnvValue) MarshalJSON() ([]byte, error) {
	if e.Secret != "" {
		return json.Marshal(struct {
			Secret string `json:"secret"`
		}{e.Secret})
	}
	return json.Marshal(e.Value)
}

func (e *EnvValue) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		*e = EnvValue{Value: s}
		return nil
	}
	var o struct {
		Secret *string `json:"secret"`
	}
	if err := json.Unmarshal(b, &o); err != nil || o.Secret == nil {
		return fmt.Errorf("an env value is a string or {\"secret\": \"<keychain ref>\"}, not %s", string(b))
	}
	*e = EnvValue{Secret: *o.Secret}
	return nil
}

// RepoRun is what a repo (a root) says about running: the recipe it names, what it overrides, or
// that it does not run. Embedded in Root, so its keys sit beside `path`.
type RepoRun struct {
	Recipe    string  `json:"recipe,omitempty"`
	Overrides *Recipe `json:"overrides,omitempty"`
	DoesntRun bool    `json:"doesntRun,omitempty"`
}

// RepoName is a root's repo name: the last element of its path.
func RepoName(r Root) string { return filepath.Base(filepath.Clean(r.Path)) }

// FieldShared and FieldRepo are the two answers of EffectiveRecipe's From.
const (
	FieldShared = "shared"
	FieldRepo   = "repo"
)

// Effective is a repo's recipe with every override applied, and where each field came from.
type Effective struct {
	Repo       string            `json:"repo"`
	RecipeName string            `json:"recipeName,omitempty"`
	DoesntRun  bool              `json:"doesntRun"`
	Recipe     Recipe            `json:"recipe"`
	From       map[string]string `json:"from"`
}

// FindRoot returns the root whose repo name is repo.
func FindRoot(p Project, repo string) (Root, bool) {
	for _, r := range p.Roots {
		if RepoName(r) == repo {
			return r, true
		}
	}
	return Root{}, false
}

// EffectiveRecipe merges a repo's recipe and its overrides. Lists and scalars replace; maps merge
// per key; processes merge by name in the shared order, the repo's new ones after.
func EffectiveRecipe(p Project, repo string) (Effective, error) {
	root, ok := FindRoot(p, repo)
	if !ok {
		return Effective{}, UserError(fmt.Sprintf("project %q has no repo named %q; its repos are %s",
			p.Name, repo, strings.Join(repoNames(p), ", ")))
	}
	if err := ValidateRecipes(p); err != nil {
		return Effective{}, err
	}
	out := Effective{Repo: repo, RecipeName: root.Recipe, DoesntRun: root.DoesntRun, From: map[string]string{}}
	if root.DoesntRun {
		return out, nil
	}
	var shared Recipe
	if root.Recipe != "" {
		shared = p.Recipes[root.Recipe]
	}
	var over Recipe
	if root.Overrides != nil {
		over = *root.Overrides
	}
	out.Recipe, out.From = MergeRecipe(shared, over)
	return out, nil
}

// MergeRecipe applies over to shared and says, per field key, which one each value came from.
func MergeRecipe(shared, over Recipe) (Recipe, map[string]string) {
	from := map[string]string{}
	var r Recipe
	list := func(key string, s, o []string) []string {
		if o != nil {
			from[key] = FieldRepo
			return append([]string{}, o...)
		}
		if s != nil {
			from[key] = FieldShared
			return append([]string{}, s...)
		}
		return nil
	}
	r.Needs = list("needs", shared.Needs, over.Needs)
	r.Copy = list("copy", shared.Copy, over.Copy)
	r.Clone = list("clone", shared.Clone, over.Clone)
	r.Services = list("services", shared.Services, over.Services)
	r.Setup = list("setup", shared.Setup, over.Setup)
	r.Teardown = list("teardown", shared.Teardown, over.Teardown)

	r.Ports = mergeMap("ports", shared.Ports, over.Ports, from)
	r.Notes = mergeMap("", shared.Notes, over.Notes, nil)
	if len(shared.Env)+len(over.Env) > 0 {
		r.Env = map[string]EnvValue{}
		for k, v := range shared.Env {
			r.Env[k] = v
			from["env."+k] = FieldShared
		}
		for k, v := range over.Env {
			r.Env[k] = v
			from["env."+k] = FieldRepo
		}
	}

	switch {
	case over.Build != nil:
		r.Build, from["build"] = ptr(*over.Build), FieldRepo
	case shared.Build != nil:
		r.Build, from["build"] = ptr(*shared.Build), FieldShared
	}
	switch {
	case over.In != nil:
		r.In, from["in"] = ptr(*over.In), FieldRepo
	case shared.In != nil:
		r.In, from["in"] = ptr(*shared.In), FieldShared
	}
	switch {
	case over.AlsoWriteEnvFile != nil:
		r.AlsoWriteEnvFile, from["alsoWriteEnvFile"] = ptr(*over.AlsoWriteEnvFile), FieldRepo
	case shared.AlsoWriteEnvFile != nil:
		r.AlsoWriteEnvFile, from["alsoWriteEnvFile"] = ptr(*shared.AlsoWriteEnvFile), FieldShared
	}
	switch {
	case over.Ready != nil:
		v := *over.Ready
		r.Ready, from["ready"] = &v, FieldRepo
	case shared.Ready != nil:
		v := *shared.Ready
		r.Ready, from["ready"] = &v, FieldShared
	}

	overByName := map[string]Process{}
	for _, p := range over.Processes {
		overByName[p.Name] = p
	}
	seen := map[string]bool{}
	for _, p := range shared.Processes {
		seen[p.Name] = true
		if o, ok := overByName[p.Name]; ok {
			if o.Command != "" {
				r.Processes = append(r.Processes, o)
				from["processes."+p.Name] = FieldRepo
			}
			continue
		}
		r.Processes = append(r.Processes, p)
		from["processes."+p.Name] = FieldShared
	}
	for _, p := range over.Processes {
		if !seen[p.Name] && p.Command != "" {
			r.Processes = append(r.Processes, p)
			from["processes."+p.Name] = FieldRepo
		}
	}
	return r, from
}

func mergeMap(prefix string, shared, over map[string]string, from map[string]string) map[string]string {
	if len(shared)+len(over) == 0 {
		return nil
	}
	out := map[string]string{}
	for k, v := range shared {
		out[k] = v
		if from != nil {
			from[prefix+"."+k] = FieldShared
		}
	}
	for k, v := range over {
		out[k] = v
		if from != nil {
			from[prefix+"."+k] = FieldRepo
		}
	}
	return out
}

func ptr[T any](v T) *T { return &v }

func repoNames(p Project) []string {
	var out []string
	for _, r := range p.Roots {
		out = append(out, RepoName(r))
	}
	return out
}

var (
	recipeNamePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*$`)
	envNamePattern    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	keychainRefRunes  = regexp.MustCompile(`^[^\s]+$`)
)

// IsSharedService says whether a recipe is a shared service: services and nothing that runs the
// app (no processes, setup, build or ready).
func IsSharedService(r Recipe) bool {
	return len(r.Services) > 0 && len(r.Processes) == 0 && len(r.Setup) == 0 && r.Build == nil && r.Ready == nil
}

// ValidateRecipes checks every recipe and every repo's run settings, and lists every problem it
// finds, each a whole sentence, in one error. A project with none of these keys is valid.
func ValidateRecipes(p Project) error {
	var problems []string
	add := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }

	names := make([]string, 0, len(p.Recipes))
	for n := range p.Recipes {
		names = append(names, n)
	}
	sort.Strings(names)
	repos := map[string]bool{}
	for _, r := range p.Roots {
		repos[RepoName(r)] = true
	}
	for _, n := range names {
		if !recipeNamePattern.MatchString(n) {
			add("Recipe name %q must be lower-case letters, digits, '.', '_' or '-', starting with a letter or digit.", n)
		}
		problems = append(problems, recipeProblems("recipe "+strconv.Quote(n), p.Recipes[n], false, p, repos)...)
	}
	for _, root := range p.Roots {
		repo := RepoName(root)
		where := "repo " + strconv.Quote(repo)
		if root.DoesntRun && (root.Recipe != "" || root.Overrides != nil) {
			add("%s is marked doesn't run, so it cannot also name a recipe or override one; clear one or the other.", where)
		}
		if root.Recipe != "" {
			if _, ok := p.Recipes[root.Recipe]; !ok {
				add("%s names recipe %q, which project.json does not define under recipes.", where, root.Recipe)
			}
		}
		if root.Overrides != nil {
			problems = append(problems, recipeProblems(where+"'s overrides", *root.Overrides, true, p, repos)...)
		}
		if !root.DoesntRun && (root.Recipe != "" || root.Overrides != nil) {
			eff, _ := MergeRecipe(p.Recipes[root.Recipe], deref(root.Overrides))
			for _, need := range eff.Needs {
				if need == repo {
					add("%s needs itself; a repo cannot be started before itself.", where)
				}
			}
		}
	}
	if cycle := needsCycle(p); cycle != "" {
		add("The needs form a loop (%s), so nothing in it could start first.", cycle)
	}
	if len(problems) == 0 {
		return nil
	}
	return UserError(strings.Join(problems, "\n"))
}

func deref(r *Recipe) Recipe {
	if r == nil {
		return Recipe{}
	}
	return *r
}

func recipeProblems(where string, r Recipe, override bool, p Project, repos map[string]bool) []string {
	var out []string
	add := func(format string, a ...any) { out = append(out, fmt.Sprintf(format, a...)) }
	for _, need := range r.Needs {
		_, isRecipe := p.Recipes[need]
		if !repos[need] && !(isRecipe && IsSharedService(p.Recipes[need])) {
			if isRecipe {
				add("%s needs %q, a recipe that is not a shared service (only services, teardown and in); a repo can need only another repo or a shared service.", where, need)
			} else {
				add("%s needs %q, which is neither a repo of this project nor a shared service.", where, need)
			}
		}
	}
	for _, k := range sortedKeys(r.Ports) {
		if !envNamePattern.MatchString(k) {
			add("%s maps port variable %q, which is not a valid variable name.", where, k)
		}
		if strings.HasPrefix(k, "WAKIL_") || k == "COMPOSE_PROJECT_NAME" || k == "COMPOSE_FILE" {
			add("%s maps %s, a name Wakil sets itself; map the repo's own variable instead.", where, k)
		}
		if strings.TrimSpace(r.Ports[k]) == "" {
			add("%s maps port variable %s to nothing; give it an expression such as $WAKIL_PORT.", where, k)
		}
	}
	for _, k := range sortedKeys(r.Env) {
		v := r.Env[k]
		if !envNamePattern.MatchString(k) {
			add("%s sets env variable %q, which is not a valid variable name.", where, k)
		}
		if strings.HasPrefix(k, "WAKIL_") || k == "COMPOSE_PROJECT_NAME" || k == "COMPOSE_FILE" {
			add("%s sets %s, a name Wakil sets itself; use another name.", where, k)
		}
		if _, both := r.Ports[k]; both {
			add("%s sets %s both under ports and under env; keep one.", where, k)
		}
		if v.Secret != "" && !keychainRefRunes.MatchString(v.Secret) {
			add("%s keeps env variable %s's secret under Keychain ref %q; a ref has no spaces.", where, k, v.Secret)
		}
	}
	for _, list := range []struct {
		field string
		globs []string
	}{{"copy", r.Copy}, {"clone", r.Clone}} {
		for _, g := range list.globs {
			if g == "" || filepath.IsAbs(g) || g == ".." || strings.HasPrefix(g, "../") || strings.Contains(g, "/../") {
				add("%s's %s entry %q must be a path inside the repo, not empty, absolute or climbing out with '..'.", where, list.field, g)
			}
		}
	}
	for _, field := range []struct {
		name string
		cmds []string
	}{{"services", r.Services}, {"setup", r.Setup}, {"teardown", r.Teardown}} {
		for i, c := range field.cmds {
			if strings.TrimSpace(c) == "" {
				add("%s's %s command %d is empty.", where, field.name, i+1)
			}
		}
	}
	seen := map[string]bool{}
	for i, proc := range r.Processes {
		if !recipeNamePattern.MatchString(proc.Name) {
			add("%s's process %d is named %q; a process name is lower-case letters, digits, '.', '_' or '-'.", where, i+1, proc.Name)
		}
		if seen[proc.Name] {
			add("%s has two processes named %q.", where, proc.Name)
		}
		seen[proc.Name] = true
		if strings.TrimSpace(proc.Command) == "" && !override {
			add("%s's process %q has no command.", where, proc.Name)
		}
	}
	if r.Build != nil && strings.TrimSpace(*r.Build) == "" && !override {
		add("%s's build is empty; remove it instead.", where)
	}
	if r.Ready != nil {
		switch {
		case r.Ready.URL != "" && r.Ready.Output != "":
			add("%s's ready has both a url and an output line; keep one.", where)
		case r.Ready.URL == "" && r.Ready.Output == "":
			add("%s's ready has neither a url nor an output line.", where)
		case r.Ready.URL != "" && !strings.HasPrefix(r.Ready.URL, "http://") && !strings.HasPrefix(r.Ready.URL, "https://"):
			add("%s's ready url %q must start with http:// or https://.", where, r.Ready.URL)
		case r.Ready.Output != "" && isRegexpPattern(r.Ready.Output):
			if _, err := regexp.Compile(r.Ready.Output[1 : len(r.Ready.Output)-1]); err != nil {
				add("%s's ready output %s is not a valid regular expression: %v.", where, r.Ready.Output, err)
			}
		}
		if r.Ready.TimeoutSeconds < 0 {
			add("%s's ready timeout is negative.", where)
		}
	}
	if r.In != nil && !repos[*r.In] {
		add("%s runs in %q, which is not a repo of this project.", where, *r.In)
	}
	return out
}

func isRegexpPattern(s string) bool {
	return len(s) >= 2 && strings.HasPrefix(s, "/") && strings.HasSuffix(s, "/")
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// needsCycle finds a loop in the needs graph (repos and shared services), or "".
func needsCycle(p Project) string {
	edges := map[string][]string{}
	for _, root := range p.Roots {
		if root.DoesntRun {
			continue
		}
		eff, _ := MergeRecipe(p.Recipes[root.Recipe], deref(root.Overrides))
		edges[RepoName(root)] = eff.Needs
	}
	for n, r := range p.Recipes {
		if IsSharedService(r) {
			edges[n] = r.Needs
		}
	}
	const (
		white = iota
		grey
		black
	)
	state := map[string]int{}
	var stack []string
	var found string
	var visit func(n string) bool
	visit = func(n string) bool {
		state[n] = grey
		stack = append(stack, n)
		for _, m := range edges[n] {
			if m == n {
				continue // reported as "needs itself"
			}
			switch state[m] {
			case grey:
				i := len(stack) - 1
				for stack[i] != m {
					i--
				}
				found = strings.Join(append(append([]string{}, stack[i:]...), m), " → ")
				return true
			case white:
				if visit(m) {
					return true
				}
			}
		}
		stack = stack[:len(stack)-1]
		state[n] = black
		return false
	}
	for _, n := range sortedKeys(edges) {
		if state[n] == white && visit(n) {
			return found
		}
	}
	return ""
}

// RecipePatch is what SaveRecipes writes: recipes by name (nil deletes) and repos' run settings
// by repo name (replaced whole).
type RecipePatch struct {
	Recipes map[string]*Recipe `json:"recipes,omitempty"`
	Repos   map[string]RepoRun `json:"repos,omitempty"`
}

// SaveRecipes applies a patch to the project file on disk (read-modify-write), validates the
// whole result first, and refuses a project of another organisation.
func SaveRecipes(projectPath string, patch RecipePatch) error {
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	project, err := LoadProject(projectPath)
	if err != nil {
		return err
	}
	if project.Org != org {
		return UserError("project " + strconv.Quote(project.Name) + " belongs to org " +
			strconv.Quote(project.Org) + ", not " + strconv.Quote(org) +
			" — a project stored in another organisation is read-only here")
	}
	if err := ApplyRecipePatch(project, patch); err != nil {
		return err
	}
	return SaveProject(projectPath, *project)
}

// ApplyRecipePatch applies a patch in memory and validates the result.
func ApplyRecipePatch(project *Project, patch RecipePatch) error {
	for name, r := range patch.Recipes {
		if r == nil {
			delete(project.Recipes, name)
			continue
		}
		if project.Recipes == nil {
			project.Recipes = map[string]Recipe{}
		}
		project.Recipes[name] = *r
	}
	for repo, run := range patch.Repos {
		found := false
		for i := range project.Roots {
			if RepoName(project.Roots[i]) == repo {
				project.Roots[i].RepoRun = run
				found = true
			}
		}
		if !found {
			return UserError(fmt.Sprintf("project %q has no repo named %q; its repos are %s",
				project.Name, repo, strings.Join(repoNames(*project), ", ")))
		}
	}
	if len(project.Recipes) == 0 {
		project.Recipes = nil
	}
	return ValidateRecipes(*project)
}
