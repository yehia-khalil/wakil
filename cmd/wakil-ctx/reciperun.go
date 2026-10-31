package main

import (
	"context"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// Workspaces piece 2, the window's side of running: get a checkout ready, run the plan's one-shot
// steps (never a command of the caller's own: only the saved recipe's, by phase), and Try. The
// processes themselves run in the window's terminals.

type recipePrepareArgs struct {
	recipePlanArgs
	FirstRun bool `json:"firstRun,omitempty" jsonschema:"copy and clone from Main's folder too (the checkout's first run)"`
}

type recipePrepareResult struct {
	Plan      map[string]any          `json:"plan"`
	Prepared  wakilcore.PrepareResult `json:"prepared"`
	SecretEnv map[string]string       `json:"secretEnv"`
	Steps     []wakilcore.StepResult  `json:"steps,omitempty"`
}

// newRecipePrepareResult keeps secretEnv an object when the plan has no secrets: the output schema says
// object, and a nil map would marshal as null.
func newRecipePrepareResult(plan map[string]any, prep wakilcore.PrepareResult, secrets map[string]string) recipePrepareResult {
	if secrets == nil {
		secrets = map[string]string{}
	}
	return recipePrepareResult{Plan: plan, Prepared: prep, SecretEnv: secrets}
}

type recipeStepsArgs struct {
	recipePlanArgs
	Phases         []string `json:"phases" jsonschema:"the plan's one-shot phases to run, in order: service, setup, build, teardown"`
	TimeoutSeconds int      `json:"timeoutSeconds,omitempty" jsonschema:"per step; default 900"`
}

type recipeStepsResult struct {
	OK    bool                   `json:"ok"`
	Steps []wakilcore.StepResult `json:"steps"`
}

type recipeSecretArgs struct {
	Project  string `json:"project" jsonschema:"the project's name"`
	Owner    string `json:"owner" jsonschema:"the recipe or repo the variable belongs to"`
	Variable string `json:"variable" jsonschema:"the env variable"`
	Value    string `json:"value" jsonschema:"the secret, kept in the Keychain and never returned"`
}

type recipeSecretResult struct {
	Ref string `json:"ref"`
}

type recipeListArgs struct {
	ProjectPath string `json:"projectPath,omitempty" jsonschema:"a project.json path; default the active project"`
}

func registerRecipeRunTools(s *mcp.Server) {
	mcp.AddTool(s, &mcp.Tool{Name: "recipe_list", Description: "The project's Running settings as stored: recipes by name; each repo (a root's folder name, in the roots' order) with its recipe, overrides and doesntRun, and its effective recipe with where each field came from; and problems, every validation problem whole (empty when the recipes are valid; an effective recipe is then left out)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeListArgs) (*mcp.CallToolResult, map[string]any, error) {
			path, p, err := recipeProject(a.ProjectPath)
			if err != nil {
				return toolErr(err), nil, nil
			}
			p.SetDir(path)
			problems := []string{}
			valid := true
			if err := wakilcore.ValidateRecipes(*p); err != nil {
				valid = false
				problems = append(problems, err.Error())
			}
			repos := []any{}
			for _, r := range p.Roots {
				name := wakilcore.RepoNameIn(path, r)
				row := map[string]any{"repo": name, "path": r.Path, "recipe": r.Recipe, "doesntRun": r.DoesntRun}
				if r.Overrides != nil {
					row["overrides"] = asObject(r.Overrides)
				}
				if valid {
					if eff, err := wakilcore.EffectiveRecipe(*p, name); err == nil {
						row["effective"] = asObject(eff)
					}
				}
				repos = append(repos, row)
			}
			recipes := map[string]any{}
			for name, r := range p.Recipes {
				recipes[name] = asObject(r)
			}
			return nil, map[string]any{"project": p.Name, "recipes": recipes, "repos": repos, "problems": problems}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_prepare", Description: "Get a checkout ready to run a repo: builds its run plan (as recipe_plan), writes the plan's files (kept out of git), on firstRun copies and clones from Main's folder (never over a file the checkout has; clone is copy-on-write), writes the .env lines when the recipe opts in, and reads the plan's secrets from the Keychain. Answers plan, prepared (wrote, copied, cloned, envFile) and secretEnv (variable to value, for the processes' terminals only). Refuses, naming each variable, a secret with no value kept."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipePrepareArgs) (*mcp.CallToolResult, recipePrepareResult, error) {
			plan, org, err := buildPlan(a.recipePlanArgs)
			if err != nil {
				return toolErr(err), recipePrepareResult{}, nil
			}
			secrets, err := wakilcore.ReadPlanSecrets(org, plan.Secrets)
			if err != nil {
				return toolErr(err), recipePrepareResult{}, nil
			}
			prep, err := wakilcore.PrepareRun(plan, a.FirstRun, secrets)
			if err != nil {
				return toolErr(err), recipePrepareResult{}, nil
			}
			return nil, newRecipePrepareResult(asObject(plan), prep, secrets), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_run_steps", Description: "Run a repo's saved one-shot steps in its checkout, by phase (service, setup, build, teardown), in the plan's order, in the operator's login shell with the plan's environment and secrets; stops at the first that fails. Each step answers its command, ok, exit code, output whole and seconds. Runs only the recipe's own commands. Cancelling the call stops the running step and its children."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeStepsArgs) (*mcp.CallToolResult, recipeStepsResult, error) {
			plan, org, err := buildPlan(a.recipePlanArgs)
			if err != nil {
				return toolErr(err), recipeStepsResult{}, nil
			}
			want := map[string]bool{}
			for _, p := range a.Phases {
				switch p {
				case wakilcore.PhaseService, wakilcore.PhaseSetup, wakilcore.PhaseBuild, wakilcore.PhaseTeardown:
					want[p] = true
				default:
					return toolErr(wakilcore.UserError("phase " + p + " is not a one-shot phase; give service, setup, build or teardown")), recipeStepsResult{}, nil
				}
			}
			secrets, err := wakilcore.ReadPlanSecrets(org, plan.Secrets)
			if err != nil {
				return toolErr(err), recipeStepsResult{}, nil
			}
			env := map[string]string{}
			for k, v := range plan.Env {
				env[k] = v
			}
			for k, v := range secrets {
				env[k] = v
			}
			timeout := time.Duration(a.TimeoutSeconds) * time.Second
			if timeout <= 0 {
				timeout = 15 * time.Minute
			}
			var steps []wakilcore.PlanStep
			for _, s := range plan.Steps {
				if want[s.Phase] {
					steps = append(steps, s)
				}
			}
			if want[wakilcore.PhaseBuild] && plan.Build != nil {
				steps = append(steps, *plan.Build)
			}
			if want[wakilcore.PhaseTeardown] {
				steps = append(steps, plan.Teardown...)
			}
			out := recipeStepsResult{OK: true, Steps: []wakilcore.StepResult{}}
			for _, s := range steps {
				r := wakilcore.ExecStep(ctx, plan.Dir, env, s.Command, timeout)
				r.Phase = s.Phase
				r.Output = scrubAll(r.Output, secrets)
				out.Steps = append(out.Steps, r)
				if !r.OK {
					out.OK = false
					break
				}
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_try", Description: "Try a repo's recipe in a throwaway workspace's checkout (decision 13): prepare it as a first run, run services and setup, start the processes headless, wait for ready, then stop the processes and run teardown. Answers passed, every step in order (phase, name, command, ok, exit code, output whole, seconds, detail) and the ready check. A need is reported, not started. Cancelling the call stops it; teardown still runs."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipePlanArgs) (*mcp.CallToolResult, wakilcore.TryResult, error) {
			plan, org, err := buildPlan(a)
			if err != nil {
				return toolErr(err), wakilcore.TryResult{}, nil
			}
			secrets, err := wakilcore.ReadPlanSecrets(org, plan.Secrets)
			if err != nil {
				return toolErr(err), wakilcore.TryResult{}, nil
			}
			res := wakilcore.TryRecipe(ctx, plan, wakilcore.TryOptions{SecretValues: secrets})
			for i := range res.Steps {
				res.Steps[i].Output = scrubAll(res.Steps[i].Output, secrets)
			}
			return nil, res, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_secret_set", Description: "Keep a Running settings secret in the Keychain under the ref derived from project, owner (the recipe or repo) and variable: run:<project>:<owner>:<variable>. Answers the ref, which a recipe's env names as {\"secret\": ref}; the value is never returned."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeSecretArgs) (*mcp.CallToolResult, recipeSecretResult, error) {
			if a.Project == "" || a.Owner == "" || a.Variable == "" {
				return toolErr(wakilcore.UserError("give the project, the owner (recipe or repo) and the variable")), recipeSecretResult{}, nil
			}
			if strings.TrimSpace(a.Value) == "" {
				return toolErr(wakilcore.UserError("the secret for " + a.Variable + " is empty; type its value")), recipeSecretResult{}, nil
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), recipeSecretResult{}, nil
			}
			ref := wakilcore.RunSecretRef(a.Project, a.Owner, a.Variable)
			if err := wakilcore.SecretSetFor(org, ref, a.Value); err != nil {
				return toolErr(err), recipeSecretResult{}, nil
			}
			return nil, recipeSecretResult{Ref: ref}, nil
		})
}

// scrubAll takes every secret value out of a step's output.
func scrubAll(text string, secrets map[string]string) string {
	for _, v := range secrets {
		if len(v) >= 4 {
			text = strings.ReplaceAll(text, v, "••••")
		}
	}
	return text
}
