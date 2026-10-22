package wakilcore

import (
	"sort"
)

// ConfigTreeOrg is the organisation node of the settings tree: the three
// strings an operator may edit, plus the id, which is the directory name
// and is therefore not editable at all.
//
// A separate type from Org because Org deliberately omits the id — it is
// the directory name, so there is one place it can be written — while a
// tree the pane draws has to say which organisation it is a tree OF.
type ConfigTreeOrg struct {
	ID              string `json:"id"`
	DisplayName     string `json:"displayName"`
	JiraBase        string `json:"jiraBase"`
	DefaultProvider string `json:"defaultProvider"`
	SpeechProvider  string `json:"speechProvider"`
	QuickProvider   string `json:"quickProvider"`
	GitName         string `json:"gitName"`
	GitEmail        string `json:"gitEmail"`
	GhostText       bool   `json:"ghostText"`
	FastPath        bool   `json:"fastPath"`
	CommitDrafts    bool   `json:"commitDrafts"`
	// 3a-iii: the accounts (no secrets) and the strategy, resolved to rebase when unset.
	GitAccounts     []GitAccount `json:"gitAccounts"`
	PullStrategy    string       `json:"pullStrategy"`
	LastCloneFolder string       `json:"lastCloneFolder"`
}

// ConfigTreeProvider is a provider binding as the settings tree draws it.
//
// **Providers sit BESIDE the projects and cannot nest** (#198). A binding
// is (organisation, provider id); it belongs to no project, and every
// project in the organisation draws on it. The credential spine cuts
// across the tree rather than along it.
//
// This is deliberately thinner than #200's account table, which adds
// credential presence, liveness and the minted token's date, and lists
// accounts homed in OTHER organisations too. This one answers "what has
// this organisation registered", which is what a read-only tree needs and
// what `list_providers` already reports.
//
// No credential of any kind appears here, and none can: nothing on this
// type reads the Keychain.
type ConfigTreeProvider struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Label     string `json:"label,omitempty"`
	ConfigDir string `json:"configDir,omitempty"`
	// Shared records that this binding did not claim the config dir's
	// headless home. Shown because it is add-time only and therefore not
	// a setting — remove-and-re-add is the honest gesture — so the pane
	// draws it as a fact rather than as a control.
	Shared bool `json:"shared,omitempty"`
	// BaseURL and Serves are a local provider's endpoint and what it is fit for. Serves is
	// resolved by kind (resolvedServes) and always present, [] when the kind serves nothing.
	BaseURL string   `json:"baseURL,omitempty"`
	Serves  []string `json:"serves"`
}

// ConfigTreeDatabase is a database as the tree draws it.
//
// **Ref is published and a value never is.** A ref is a Keychain ENTRY
// NAME; the credential it names is read by the driver, at query time, and
// never by anything on this path. `Writable` is derived from `WriteRef`
// rather than stored, for the same reason `DatabaseInfo` derives it: a
// stored copy is a second source of truth for a safety property and would
// drift (issue #14).
//
// Unlike `DatabaseInfo`, which is what an AGENT is told, this carries the
// refs — because the operator's own settings pane is exactly where a
// Keychain entry name is worth reading, and it is the thing #207's
// presence column will be computed from.
type ConfigTreeDatabase struct {
	Name     string `json:"name"`
	Driver   string `json:"driver"`
	Ref      string `json:"ref"`
	WriteRef string `json:"writeRef,omitempty"`
	Writable bool   `json:"writable"`
}

// ConfigTreeEnvironment is the level that actually holds things, and the
// reason the tree is four deep rather than three: an ENVIRONMENT holds
// `Databases` and `API`, not a project (`config.go`).
type ConfigTreeEnvironment struct {
	Name string `json:"name"`
	// Databases is never nil, so an environment with none marshals to []
	// rather than null. An environment that declares no databases and one
	// that could not be read are different facts and must not share a
	// representation.
	Databases []ConfigTreeDatabase `json:"databases"`
	// API is never nil, for `Databases`' reason: an environment with no
	// API entries and one that could not be read are different facts.
	//
	// **A LIST, because it became one.** 2e modelled this as a single
	// optional entry and said in this very comment that "a form built on
	// today's API shape is one rebuilt on someone else's schedule" — and
	// 2c-iv then made `Environment.API` a `[]ApiConfig` of NAMED entries,
	// so the same request can run against staging and then production.
	// The prediction was right; this is the rebuild. Still drawn
	// READ-ONLY, which is what kept the cost to a shape change.
	API []ApiConfig `json:"api"`
}

// ConfigTreeProject is one project of the organisation.
type ConfigTreeProject struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Roots []Root `json:"roots"`
	// Scopes is the project's PM scope when it declares one. Read-only
	// here; nothing in 2e edits it.
	Scopes Scopes `json:"scopes"`
	// Environments is sorted by name. A registry is a map and Go
	// randomises map iteration, so without this the tree reorders itself
	// between two reads of an unchanged disk — which the pane, reading
	// disk on every read, would show as movement.
	Environments []ConfigTreeEnvironment `json:"environments"`
	// Editor is the project's editor settings with defaults filled (3b-v). Never absent: a
	// project with no editor block shows the defaults its Editor node edits.
	Editor EditorProjectValues `json:"editor"`
}

// ConfigTree is the whole of one organisation's configuration, shaped the
// way the settings pane draws it (#198):
//
//	Organisation          three strings
//	Providers             (organisation, provider id) — org-level, cannot nest
//	Projects
//	  └ project           roots, scopes, environments
//	      └ environment   ← holds the databases and the api
//	          ├ Databases
//	          └ API
//
// **The pane caches nothing at all**, so this is called on open and on
// every read rather than held. That beats a watcher this app has never
// had and makes staleness structurally impossible; it was measured
// affordable during the map.
//
// **Partiality travels with the data**, the same house rule
// `ProjectListing`, `SessionList` and `IssuePage` follow: a project whose
// file could not be read, or which declares another organisation, is
// NAMED rather than dropped. A pane that draws "could not look" as "there
// is nothing there" is the failure this rule exists to prevent.
type ConfigTree struct {
	Org       ConfigTreeOrg        `json:"org"`
	Providers []ConfigTreeProvider `json:"providers"`
	Projects  []ConfigTreeProject  `json:"projects"`
	// Editor is the app-wide editor tier (~/.wakil/settings.json) with defaults filled — not
	// this organisation's, but the pane draws it beside the organisation, so it travels in the
	// pane's one read. EditorError is that file's read or parse error, whole (Rule 8); Editor then
	// holds the defaults.
	Editor      EditorAppValues `json:"editor"`
	EditorError string          `json:"editorError,omitempty"`

	// Misfiled names registry entries whose project.json declares another
	// organisation. Same field, same meaning, as ProjectListing's.
	Misfiled []MisfiledProject `json:"misfiled,omitempty"`
	// Unreadable names registry entries whose project.json could not be
	// read at all.
	Unreadable []string `json:"unreadable,omitempty"`
	// ProvidersSkipped names provider records that could not be parsed,
	// carried for the same reason as the two above.
	ProvidersSkipped []string `json:"providersSkipped,omitempty"`
}

// LoadConfigTree reads the active organisation's whole configuration from
// disk.
//
// Every slice it returns is non-nil, so the wire carries `[]` where there
// is nothing rather than `null`: the pane draws a node for each of the
// three top-level items whether or not it holds anything, and `null`
// would make "none" and "not answered" indistinguishable at the one place
// that has to tell them apart.
func LoadConfigTree() (ConfigTree, error) {
	org, err := CurrentOrg()
	if err != nil {
		return emptyConfigTree(""), err
	}
	return LoadConfigTreeFor(org)
}

// LoadConfigTreeFor reads one named organisation's configuration.
//
// Split from ConfigTree the same way LoadOrgFor is split from LoadOrg, and
// for the same reason: a caller that already knows which organisation it
// means should not have to go through the ambient one to say so.
func LoadConfigTreeFor(org string) (ConfigTree, error) {
	tree := emptyConfigTree(org)

	app, err := LoadAppSettings()
	if err != nil {
		tree.EditorError = err.Error()
	}
	tree.Editor = app.Editor.Resolved()

	record, err := LoadOrgFor(org)
	if err != nil {
		return tree, err
	}
	tree.Org = ConfigTreeOrg{
		ID:              org,
		DisplayName:     record.DisplayName,
		JiraBase:        record.JiraBase,
		DefaultProvider: record.DefaultProvider,
		SpeechProvider:  record.SpeechProvider,
		QuickProvider:   record.QuickProvider,
		GitName:         record.GitName,
		GitEmail:        record.GitEmail,
	}
	tree.Org.GhostText = resolveOrgSwitch(record.GhostText, app.Editor.Resolved().GhostText)
	tree.Org.FastPath = resolveOrgSwitch(record.FastPath, quickProviderIsLocal(org, record.QuickProvider))
	tree.Org.CommitDrafts = resolveOrgSwitch(record.CommitDrafts, true)
	tree.Org.GitAccounts = append([]GitAccount{}, record.GitAccounts...)
	tree.Org.PullStrategy = PullStrategyOf(record)
	tree.Org.LastCloneFolder = record.LastCloneFolder

	providers, skipped, err := listProvidersFor(org)
	if err != nil {
		return tree, err
	}
	tree.ProvidersSkipped = skipped
	for _, p := range providers {
		tree.Providers = append(tree.Providers, configTreeProviderRow(p))
	}
	sort.Slice(tree.Providers, func(i, j int) bool { return tree.Providers[i].ID < tree.Providers[j].ID })

	registry, err := LoadRegistryFor(org)
	if err != nil {
		return tree, err
	}
	names := make([]string, 0, len(registry))
	for name := range registry {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		entry := registry[name]
		project, err := LoadProject(entry.Path)
		if err != nil {
			tree.Unreadable = append(tree.Unreadable, name)
			continue
		}
		// The project's own file is AUTHORITATIVE for org; registry
		// placement is an index and not an assertion of ownership. Same
		// rule, same reason, as ListProjectsForOrg.
		if project.Org != org {
			tree.Misfiled = append(tree.Misfiled, MisfiledProject{
				Name: name, Path: entry.Path, FiledUnder: org, DeclaredOrg: project.Org,
			})
			continue
		}
		tree.Projects = append(tree.Projects, configTreeProject(name, entry.Path, project))
	}

	return tree, nil
}

func configTreeProject(name, path string, project *Project) ConfigTreeProject {
	out := ConfigTreeProject{
		Name:         name,
		Path:         path,
		Roots:        project.Roots,
		Scopes:       project.Scopes,
		Environments: []ConfigTreeEnvironment{},
		Editor:       project.Editor.Resolved(),
	}
	if out.Roots == nil {
		out.Roots = []Root{}
	}

	environmentNames := make([]string, 0, len(project.Environments))
	for environmentName := range project.Environments {
		environmentNames = append(environmentNames, environmentName)
	}
	sort.Strings(environmentNames)

	for _, environmentName := range environmentNames {
		environment := project.Environments[environmentName]
		databases := make([]ConfigTreeDatabase, 0, len(environment.Databases))
		for _, d := range environment.Databases {
			databases = append(databases, ConfigTreeDatabase{
				Name: d.Name, Driver: d.Driver, Ref: d.Ref,
				WriteRef: d.WriteRef, Writable: d.WriteRef != "",
			})
		}
		api := environment.API
		if api == nil {
			api = []ApiConfig{}
		}
		out.Environments = append(out.Environments, ConfigTreeEnvironment{
			Name: environmentName, Databases: databases, API: api,
		})
	}
	return out
}

func emptyConfigTree(org string) ConfigTree {
	return ConfigTree{
		Org:       ConfigTreeOrg{ID: org},
		Providers: []ConfigTreeProvider{},
		Projects:  []ConfigTreeProject{},
		Editor:    EditorAppSettings{}.Resolved(),
	}
}

// configTreeProviderRow is one provider as the tree draws it.
func configTreeProviderRow(p Provider) ConfigTreeProvider {
	return ConfigTreeProvider{
		ID: p.ID, Kind: p.Kind, Label: p.Label,
		ConfigDir: p.ConfigDir, Shared: p.Shared,
		BaseURL: p.BaseURL, Serves: resolvedServes(p),
	}
}

// resolveOrgSwitch is an org switch's value: the org's own, else the default it falls back to.
func resolveOrgSwitch(own *bool, fallback bool) bool {
	if own != nil {
		return *own
	}
	return fallback
}

// quickProviderIsLocal reports whether the org's quick provider is a local endpoint: the fast
// path's default (3b-ix), because over Claude every line would wait for it first.
func quickProviderIsLocal(org, id string) bool {
	if id == "" {
		return false
	}
	p, err := LoadProviderFor(org, id)
	return err == nil && p.Kind == ProviderKindLocal
}
