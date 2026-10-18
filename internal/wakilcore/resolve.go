package wakilcore

import (
	"fmt"
	"os"
)

type Resolved struct {
	Org     string
	Project *Project
	// ProjectKey is the active project's registry key — the name
	// WAKIL_PROJECT pins by (ReadActive looks it up in the registry). It is
	// not Project.Name: the key and project.json's "name" are written
	// independently and can differ, so the app needs this one to build a
	// pin and the other to draw. Tagged capitalized like RootPaths below.
	ProjectKey  string `json:"ProjectKey,omitempty"`
	ProjectPath string
	Environment string
	Provider    ProviderReport
	// RootPaths is Project.Roots resolved to absolute paths, in
	// declaration order — what ProjectRootPaths returns. Reported on the
	// wire so the app does not have to re-derive it: root paths may be
	// relative to the project directory, and resolving them in Swift
	// would be a second implementation of a rule that lives here.
	//
	// Tagged "RootPaths", capitalized, to match every other field at this
	// level (Org, Project, ProjectPath, Environment, Provider), none of
	// which carry a tag and so all serialise under their capitalized Go
	// name. ContextStore.swift parses this level by capitalized key (see
	// its doc comment's observed get_context output); an explicit
	// capitalized tag here records that as a deliberate choice rather than
	// leaving it to read as a forgotten tag.
	RootPaths []string `json:"RootPaths,omitempty"`
	// ActiveProvider is active.json's Provider field (Task 7's fourth
	// axis on ActiveContext), echoed here so get_context's one call
	// carries it the same way it already carries RootPaths, rather than
	// asking the app to open the active-context file itself or make a
	// second call to learn it.
	//
	// Deliberately a separate field from Provider (ProviderReport) just
	// below, not a fifth field folded into that struct: Provider is an
	// advisory comparison computed fresh on every Resolve() call — this
	// project's declared default (or the org's, as a fallback) versus
	// whatever WAKIL_PROVIDER the current process happened to launch
	// under — and neither of those two is what a provider switch changes.
	// ActiveProvider is the persisted, pick-time selection itself: the
	// value `ctx_set_provider` (driven by `--dispatch`, or by the app's
	// own ⌘P picker calling the identical write) puts into active.json
	// without a relaunch, and the value the harness factory
	// (2b-vi Task 6) rebuilds its MCP config from. Merging it into
	// ProviderReport would make one struct answer two different
	// questions — "what does this project prefer, and did the launcher
	// match it" versus "what did the operator actually pick just now" —
	// under field names (Selected/Running) that already mean something
	// else.
	//
	// Capitalized and explicitly tagged for the same reason as RootPaths
	// above: every top-level field on Resolved that ContextStore.swift
	// reads is a capitalized key, and RootPaths already established that
	// an explicit tag records that choice deliberately rather than
	// leaving it to read as a forgotten one. omitempty because an org
	// that has never picked a provider — every org before 2b-vi, and any
	// org that only ever runs one account — must not gain a spurious key.
	ActiveProvider string `json:"ActiveProvider,omitempty"`
}

// ProviderReport says which provider should be working on the active
// project and which one actually is. It never blocks; see
// ProjectEntry.Provider for why.
type ProviderReport struct {
	Selected string `json:"selected,omitempty"`
	Running  string `json:"running,omitempty"`
	Match    bool   `json:"match"`
	Note     string `json:"note,omitempty"`
}

// providerReport builds the report. Every failure inside is soft: this is
// advisory information hanging off a call whose real job is resolving the
// active context, and a broken provider record must not take get_context
// down with it.
func providerReport(org string, projectPath string) ProviderReport {
	var rep ProviderReport
	// Matched by PATH, not by name. The registry key and project.json's
	// "name" field are written independently and can differ; the active
	// context stores a path, so the path is the only join key that cannot
	// silently miss.
	if reg, err := LoadRegistryFor(org); err == nil {
		for _, e := range reg {
			if e.Path == projectPath {
				rep.Selected = e.Provider
				break
			}
		}
	}
	if rep.Selected == "" {
		if o, err := LoadOrgFor(org); err == nil {
			rep.Selected = o.DefaultProvider
		}
	}
	running, runErr := CurrentProvider()
	rep.Running = running
	switch {
	case runErr != nil:
		// CurrentProvider fails only one way: WAKIL_PROVIDER is set but
		// names an id not registered in this org (spec §3.2 — "an unknown
		// id is an error"). That is a materially different fact from
		// "nothing was declared" (the case below), and reporting it with
		// the same "did not declare" note would be false: the launcher
		// DID declare one. This must still never block Resolve — get_context's
		// whole point is to report on the provider mismatch, not enforce
		// it — so the error is named here, not returned.
		rep.Note = fmt.Sprintf("WAKIL_PROVIDER names %q, which is not registered in this org", os.Getenv("WAKIL_PROVIDER"))
	case rep.Running == "":
		rep.Note = "the launcher did not declare WAKIL_PROVIDER, so the running provider is unknown"
	case rep.Selected == "":
		rep.Note = "this project names no provider and the org has no default"
		rep.Match = true
	default:
		rep.Match = rep.Selected == rep.Running
		if !rep.Match {
			rep.Note = "this project is set to run on " + rep.Selected + " — nothing is blocked, but history and rate limits belong to " + rep.Running
		}
	}
	return rep
}

// projectKey is the registry key for the active project: the pin itself
// when this process is pinned, else the entry whose path is projectPath —
// by path, for the reason providerReport gives. Two keys naming one path
// resolve to the first in sort order, so the answer is stable. "" when no
// entry matches.
func projectKey(org string, projectPath string) string {
	if pinned, _ := PinnedPlace(); pinned != "" {
		return pinned
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return ""
	}
	key := ""
	for k, e := range reg {
		if e.Path == projectPath && (key == "" || k < key) {
			key = k
		}
	}
	return key
}

func Resolve() (*Resolved, error) {
	active, err := ReadActive()
	if err != nil {
		return nil, err
	}
	if active.Project == "" {
		return nil, UserError("no active project — run set_project first")
	}
	// active.Project stores the project.json path.
	proj, err := LoadProject(active.Project)
	if err != nil {
		return nil, UserError("active project config unreadable: " + err.Error())
	}
	currentOrg, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	if proj.Org != currentOrg {
		return nil, UserError(fmt.Sprintf("active project %q belongs to org %q but the active org is %q — relaunch with WAKIL_ORG set to the project's org, or set a different project", proj.Name, proj.Org, currentOrg))
	}
	out := Resolved{
		Org:            currentOrg,
		Project:        proj,
		ProjectKey:     projectKey(currentOrg, active.Project),
		ProjectPath:    active.Project,
		Environment:    active.Environment,
		Provider:       providerReport(currentOrg, active.Project),
		ActiveProvider: active.Provider,
	}
	out.RootPaths = ProjectRootPaths(out)
	return &out, nil
}

// PartialResolved is what get_context reports when Resolve() fails.
//
// Resolve() needs an active project and a readable project.json; the ORG
// needs neither. It is in the process's own environment, and the active
// provider is active.json's fourth axis in the org's own directory. Before
// this existed, a fresh org — no active project, the first state a new
// operator meets — reported Org:"" while the server knew perfectly well
// which org it was, and a window trusting that answer would draw one org's
// name over another org's credentials (Invariant 4's own subject).
//
// Both fields are best-effort: this is the error path, and a second error
// raised while reporting the first one helps nobody. An unreadable
// active.json yields an empty ActiveProvider, not a failure.
func PartialResolved() *Resolved {
	out := &Resolved{}
	if org, err := CurrentOrg(); err == nil {
		out.Org = org
	}
	if active, err := ReadActive(); err == nil {
		out.ActiveProvider = active.Provider
	}
	return out
}

func ResolveEnvironment() (Environment, error) {
	r, err := Resolve()
	if err != nil {
		return Environment{}, err
	}
	env, ok := r.Project.Environments[r.Environment]
	if !ok {
		return Environment{}, UserError("no active environment — choose one of the project's environments")
	}
	return env, nil
}

func SetProjectChecked(name string) error {
	if project, _ := PinnedPlace(); project != "" {
		return ErrPinned()
	}
	reg, err := LoadRegistry()
	if err != nil {
		return err
	}
	entry, ok := reg[name]
	if !ok {
		return UserError("unknown project: " + name)
	}
	proj, err := LoadProject(entry.Path)
	if err != nil {
		return UserError("project config unreadable: " + err.Error())
	}
	currentOrg, err := CurrentOrg()
	if err != nil {
		return err
	}
	if proj.Org != currentOrg {
		return UserError(fmt.Sprintf("project %q is filed under org %q but its project.json declares org %q — the project file wins, so fix the mismatch with: wakil project rm %s, then wakil project add %s --path %s --org %s (wakil project add refuses an existing name, so rm must come first)", name, currentOrg, proj.Org, name, name, entry.Path, proj.Org))
	}
	active, err := ReadActiveUnpinned()
	if err != nil {
		return err
	}
	active.Project = entry.Path
	if _, ok := proj.Environments[active.Environment]; !ok {
		active.Environment = ""
	}
	return WriteActive(active)
}
