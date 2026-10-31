package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// Workspaces piece 2: how a repo runs. Every tool here reads, except recipe_save, which writes the
// project's project.json read-modify-write. The window's Running settings and Run / Stop call
// them; executing a plan (terminals, the Keychain read of secrets, writing files) is the window's.
//
// **Recipes travel as plain JSON objects.** A recipe's env value is a string or {"secret": ref},
// which no Go struct schema can say, so the recipe-carrying tools answer map[string]any and take
// recipes as objects, decoded here through wakilcore's own types (and their errors).

type recipeRepoArgs struct {
	Repo        string `json:"repo" jsonschema:"the repo: a root's folder name"`
	ProjectPath string `json:"projectPath,omitempty" jsonschema:"a project.json path; default the active project"`
}

type recipeDraftAllArgs struct {
	Repos       []string `json:"repos,omitempty" jsonschema:"the repos to read; default every root"`
	ProjectPath string   `json:"projectPath,omitempty" jsonschema:"a project.json path; default the active project"`
}

type recipeSaveArgs struct {
	Recipes     map[string]any `json:"recipes,omitempty" jsonschema:"recipes by name, each a recipe object; null deletes one"`
	Repos       map[string]any `json:"repos,omitempty" jsonschema:"repos by name, each {recipe, overrides, doesntRun}, replaced whole"`
	ProjectPath string         `json:"projectPath,omitempty" jsonschema:"a project.json path; default the active project"`
}

type recipePlanArgs struct {
	Repo        string                    `json:"repo" jsonschema:"a repo, or a shared service's recipe name"`
	Workspace   string                    `json:"workspace" jsonschema:"the workspace slug"`
	Checkouts   []wakilcore.CheckoutPorts `json:"checkouts" jsonschema:"every repo of the workspace: its folder (checkout, or Main's folder) and its block's first port (0 for none)"`
	ProjectPath string                    `json:"projectPath,omitempty" jsonschema:"a project.json path; default the active project"`
	Project     string                    `json:"project,omitempty" jsonschema:"the workspace's project by registry key, one of the active organisation's; used when projectPath is not given"`
}

type readyWaitArgs struct {
	URL            string `json:"url,omitempty" jsonschema:"a loopback URL to poll until it answers 200 to 399"`
	Output         string `json:"output,omitempty" jsonschema:"a ready line: a substring, or /a regexp/"`
	Text           string `json:"text,omitempty" jsonschema:"the output so far, matched once against output"`
	TimeoutSeconds int    `json:"timeoutSeconds,omitempty" jsonschema:"how long to poll the url; default 120"`
}

type portsAllocateArgs struct {
	Existing map[string]int `json:"existing,omitempty" jsonschema:"checkout key to its block's first port, as workspaces.json keeps them"`
	Want     []string       `json:"want" jsonschema:"checkout keys that need a block, in order"`
}

type composeOverrideArgs struct {
	Repo        string `json:"repo" jsonschema:"the repo"`
	Workspace   string `json:"workspace" jsonschema:"the workspace slug"`
	Port        int    `json:"port" jsonschema:"the checkout's block's first port"`
	Dir         string `json:"dir,omitempty" jsonschema:"the checkout's folder; default the repo's own folder"`
	Reserved    []int  `json:"reserved,omitempty" jsonschema:"block offsets already used; default those the repo's recipe ports use"`
	ProjectPath string `json:"projectPath,omitempty" jsonschema:"a project.json path; default the active project"`
}

// recipeProject loads the named or active project, refusing one of another organisation.
func recipeProject(projectPath string) (string, *wakilcore.Project, error) {
	if projectPath == "" {
		r, err := wakilcore.Resolve()
		if err != nil {
			return "", nil, err
		}
		return r.ProjectPath, r.Project, nil
	}
	p, err := wakilcore.LoadProject(projectPath)
	if err != nil {
		return "", nil, wakilcore.UserError(err.Error())
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return "", nil, err
	}
	if p.Org != org {
		return "", nil, wakilcore.UserError(fmt.Sprintf("project %q belongs to org %q, not %q", p.Name, p.Org, org))
	}
	return projectPath, p, nil
}

func repoDir(projectPath string, p *wakilcore.Project, repo string) (string, error) {
	dirs := wakilcore.RepoDirs(projectPath, *p)
	dir, ok := dirs[repo]
	if !ok {
		return "", wakilcore.UserError(fmt.Sprintf("project %q has no repo named %q", p.Name, repo))
	}
	return dir, nil
}

// buildPlan builds a repo's run plan, every folder confined to the project's repos and the
// organisation's workspaces; it also answers the organisation the plan's secrets are under.
func buildPlan(a recipePlanArgs) (wakilcore.RunPlan, string, error) {
	projectPath := a.ProjectPath
	if projectPath == "" && a.Project != "" {
		r, err := wakilcore.ResolveProject(a.Project)
		if err != nil {
			return wakilcore.RunPlan{}, "", err
		}
		projectPath = r.ProjectPath
	}
	path, p, err := recipeProject(projectPath)
	if err != nil {
		return wakilcore.RunPlan{}, "", err
	}
	p.SetDir(path)
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return wakilcore.RunPlan{}, "", err
	}
	dirs := wakilcore.RepoDirs(path, *p)
	for _, c := range a.Checkouts {
		if err := wakilcore.ConfineRunDir(c.Path, org, dirs); err != nil {
			return wakilcore.RunPlan{}, "", err
		}
	}
	mainDir := dirs[a.Repo]
	if r, ok := p.Recipes[a.Repo]; ok && r.In != nil {
		mainDir = dirs[*r.In]
	}
	plan, err := wakilcore.BuildRunPlan(*p, wakilcore.PlanInput{
		Org: org, Workspace: a.Workspace, Repo: a.Repo, MainDir: mainDir, Checkouts: a.Checkouts,
	})
	return plan, org, err
}

// asObject is v as the JSON object a client sees.
func asObject(v any) map[string]any {
	b, _ := json.Marshal(v)
	out := map[string]any{}
	json.Unmarshal(b, &out)
	return out
}

func registerRecipeTools(s *mcp.Server) {
	mcp.AddTool(s, &mcp.Tool{Name: "recipe_detect", Description: "Draft how one repo of the project runs, from its files alone (no model): kind, a recipe (needs, ports, env, copy, clone, services, setup, processes, build, ready, teardown) whose notes say where each field came from, doesntRun with why, the runtime versions it pins, the .env.example keys its .env lacks, the hosts its example env points at, what its compose file means for running twice, and questions it could not decide. Reads only; saves nothing."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeRepoArgs) (*mcp.CallToolResult, map[string]any, error) {
			path, p, err := recipeProject(a.ProjectPath)
			if err != nil {
				return toolErr(err), nil, nil
			}
			dir, err := repoDir(path, p, a.Repo)
			if err != nil {
				return toolErr(err), nil, nil
			}
			d, err := wakilcore.DetectRecipe(dir, wakilcore.DetectOptions{Managers: wakilcore.MachineManagers()})
			if err != nil {
				return toolErr(err), nil, nil
			}
			d.Repo = a.Repo
			return nil, asObject(d), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_draft_all", Description: "Draft recipes for many repos at once: reads each repo (default every root), groups alike ones under one shared recipe with each repo's differences as its overrides, proposes shared services (a compose service several repos' example env files point at, run once per workspace), lists repos with nothing to run, and the questions it could not decide. Answers recipes, repos, groups, sharedServices, nothingToRun and questions. Saves nothing."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeDraftAllArgs) (*mcp.CallToolResult, map[string]any, error) {
			path, p, err := recipeProject(a.ProjectPath)
			if err != nil {
				return toolErr(err), nil, nil
			}
			repos := a.Repos
			if len(repos) == 0 {
				for _, r := range p.Roots {
					repos = append(repos, wakilcore.RepoNameIn(path, r))
				}
			}
			managers := wakilcore.MachineManagers()
			var drafts []wakilcore.Draft
			for _, repo := range repos {
				dir, err := repoDir(path, p, repo)
				if err != nil {
					return toolErr(err), nil, nil
				}
				d, err := wakilcore.DetectRecipe(dir, wakilcore.DetectOptions{Managers: managers})
				if err != nil {
					return toolErr(err), nil, nil
				}
				d.Repo = repo
				drafts = append(drafts, d)
			}
			return nil, asObject(wakilcore.DraftAllRecipes(drafts)), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_effective", Description: "A repo's recipe as it runs: the shared recipe it names with its own overrides applied (lists and single values replace, ports and env merge per variable, processes by name; an override's empty command removes a shared process), and from, saying per field (needs, ports.<VAR>, env.<VAR>, processes.<name>, …) whether it is shared or the repo's own. Refuses, with every problem whole, a project whose recipes do not validate."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeRepoArgs) (*mcp.CallToolResult, map[string]any, error) {
			path, p, err := recipeProject(a.ProjectPath)
			if err != nil {
				return toolErr(err), nil, nil
			}
			p.SetDir(path)
			eff, err := wakilcore.EffectiveRecipe(*p, a.Repo)
			if err != nil {
				return toolErr(err), nil, nil
			}
			return nil, asObject(eff), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_save", Description: "Save recipes and repos' run settings into project.json, read-modify-write: recipes by name (an object replaces the recipe, null deletes it) and repos by name ({recipe, overrides, doesntRun}, replaced whole). The whole result is validated first and nothing is written unless every recipe and repo is valid; the refusal lists every problem. A secret env value is {\"secret\": \"<keychain ref>\"}, never the value. Refuses a project of another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipeSaveArgs) (*mcp.CallToolResult, empty, error) {
			path, _, err := recipeProject(a.ProjectPath)
			if err != nil {
				return toolErr(err), empty{}, nil
			}
			var patch wakilcore.RecipePatch
			raw, _ := json.Marshal(map[string]any{"recipes": a.Recipes, "repos": a.Repos})
			if err := json.Unmarshal(raw, &patch); err != nil {
				return toolErr(wakilcore.UserError("the recipes cannot be read: " + err.Error())), empty{}, nil
			}
			if err := wakilcore.SaveRecipes(path, patch); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_plan", Description: "The run plan for a repo (or a shared service) in a workspace: dir; env (WAKIL_PORT, WAKIL_PORT_1…9, WAKIL_PORT_<REPO>, WAKIL_DIR, WAKIL_DIR_<REPO>, WAKIL_WORKSPACE, WAKIL_REPO, COMPOSE_PROJECT_NAME, COMPOSE_FILE when an override is needed, the recipe's ports and env expanded); secrets as Keychain service names to read at run time, never values; envFile when the recipe also writes .env; files to write first (the compose port override); steps in order (need, copy, clone, service, setup, process) each with once (workspace, checkout) and longRunning; build; ready (url expanded, or an output line, with a timeout); teardown; warnings (a compose file that cannot run twice). Commands are not expanded. Runs nothing."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recipePlanArgs) (*mcp.CallToolResult, map[string]any, error) {
			plan, _, err := buildPlan(a)
			if err != nil {
				return toolErr(err), nil, nil
			}
			return nil, asObject(plan), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "recipe_ready_wait", Description: "Check that an app is up. With url (on this machine: localhost, 127.0.0.1 or ::1), poll it until it answers 200 to 399, the timeout passes (default 120 s) or the call is cancelled. With output and text, say once whether text holds the ready line (a substring, or /a regexp/). Answers ready and a detail sentence."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a readyWaitArgs) (*mcp.CallToolResult, wakilcore.ReadyResult, error) {
			switch {
			case a.URL != "" && a.Output != "":
				return toolErr(wakilcore.UserError("give url or output, not both")), wakilcore.ReadyResult{}, nil
			case a.Output != "":
				ok, err := wakilcore.MatchReadyOutput(a.Output, a.Text)
				if err != nil {
					return toolErr(err), wakilcore.ReadyResult{}, nil
				}
				detail := fmt.Sprintf("the output does not show %s yet", a.Output)
				if ok {
					detail = fmt.Sprintf("the output shows %s", a.Output)
				}
				return nil, wakilcore.ReadyResult{Ready: ok, Detail: detail}, nil
			case a.URL != "":
				u, err := url.Parse(a.URL)
				if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
					return toolErr(wakilcore.UserError(fmt.Sprintf("ready url %q must be an http or https URL", a.URL))), wakilcore.ReadyResult{}, nil
				}
				switch strings.ToLower(u.Hostname()) {
				case "localhost", "127.0.0.1", "::1":
				default:
					return toolErr(wakilcore.UserError(fmt.Sprintf("ready url %q is not on this machine; a ready check polls only localhost, 127.0.0.1 or ::1", a.URL))), wakilcore.ReadyResult{}, nil
				}
				timeout := time.Duration(a.TimeoutSeconds) * time.Second
				if timeout <= 0 {
					timeout = wakilcore.DefaultReadyTimeoutSeconds * time.Second
				}
				return nil, wakilcore.WaitReadyURL(ctx, nil, a.URL, timeout, 500*time.Millisecond), nil
			}
			return toolErr(wakilcore.UserError("give a url to poll, or an output line and the text to look in")), wakilcore.ReadyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ports_allocate", Description: "Hand out port blocks of ten from 41200 upward: every key in existing keeps its block; each key in want without one gets the lowest block none of whose ports is listening on this machine or held by another key. Answers blocks (key to first port) and taken (the listening ports stepped over). Keeps nothing: the caller records the blocks. Refuses, naming the ports in use, when no block is free."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a portsAllocateArgs) (*mcp.CallToolResult, wakilcore.PortAllocation, error) {
			out, err := wakilcore.AllocatePortBlocks(a.Existing, a.Want, wakilcore.ListeningProbe)
			if err != nil {
				return toolErr(err), wakilcore.PortAllocation{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "compose_override", Description: "The compose port override for a repo's checkout: reads its compose file (compose.yaml, compose.yml, docker-compose.yaml or docker-compose.yml) and moves every fixed published host port into the block starting at port, at the offsets the recipe's ports do not already use. Answers projectName (COMPOSE_PROJECT_NAME), composeFile, file (.wakil/compose.ports.yml), yaml (empty when nothing is fixed; ports lists use !override), remaps, the port variables the file already reads, containerNames, and cannotRunTwice, the sentence for a compose file that names its containers. Writes nothing."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a composeOverrideArgs) (*mcp.CallToolResult, wakilcore.ComposeOverrideResult, error) {
			path, p, err := recipeProject(a.ProjectPath)
			if err != nil {
				return toolErr(err), wakilcore.ComposeOverrideResult{}, nil
			}
			p.SetDir(path)
			dirs := wakilcore.RepoDirs(path, *p)
			dir := a.Dir
			if dir == "" {
				if dir, err = repoDir(path, p, a.Repo); err != nil {
					return toolErr(err), wakilcore.ComposeOverrideResult{}, nil
				}
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.ComposeOverrideResult{}, nil
			}
			if err := wakilcore.ConfineRunDir(dir, org, dirs); err != nil {
				return toolErr(err), wakilcore.ComposeOverrideResult{}, nil
			}
			reserved := a.Reserved
			if reserved == nil {
				if eff, err := wakilcore.EffectiveRecipe(*p, a.Repo); err == nil {
					reserved = wakilcore.ReservedOffsets(eff.Recipe.Ports)
				}
			}
			out, err := wakilcore.ComposeOverrideForDir(dir, a.Workspace, a.Repo, a.Port, reserved)
			if err != nil {
				return toolErr(err), wakilcore.ComposeOverrideResult{}, nil
			}
			return nil, out, nil
		})
}
