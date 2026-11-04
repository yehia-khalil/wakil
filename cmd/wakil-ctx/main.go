package main

import (
	"context"
	"log"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type empty struct{}

type configTreeArgs struct {
	ID string `json:"id,omitempty" jsonschema:"read this organisation's configuration instead of the active one"`
}

type capacityArgs struct {
	Refresh bool `json:"refresh,omitempty" jsonschema:"probe each claude-code account whose reading is over a minute old before answering; costs a 1-token request per account"`
}
type nameArg struct {
	Name string `json:"name" jsonschema:"the name to select"`
}
type idArg struct {
	ID string `json:"id" jsonschema:"the session id"`
}
type readSessionArgs struct {
	ID    string `json:"id" jsonschema:"the session id"`
	Limit int    `json:"limit" jsonschema:"keep only the last N thread entries; 0 or absent keeps all"`
}
type sessionParentArgs struct {
	Child  string `json:"child" jsonschema:"the forked session's id"`
	Parent string `json:"parent" jsonschema:"the session it was forked from"`
}
type recordCapacityArgs struct {
	Provider string                    `json:"provider" jsonschema:"the claude-code provider (account) id"`
	FiveHour *wakilcore.CapacityWindow `json:"fiveHour,omitempty" jsonschema:"the 5-hour window"`
	SevenDay *wakilcore.CapacityWindow `json:"sevenDay,omitempty" jsonschema:"the weekly window, when reported"`
	Month    *wakilcore.CapacityWindow `json:"month,omitempty" jsonschema:"the monthly window, when there is no 5-hour one"`
	AsOf     string                    `json:"asOf" jsonschema:"when the reading was taken, RFC 3339"`
}

// toolErr converts err into an MCP tool-error result carrying a single
// human sentence — never a raw stack trace. It delegates to mcpx.ToolErr
// (shared across every cmd/ server) with this binary's own name, so the
// fallback message for a non-UserError reads "wakil-ctx: an internal
// error occurred: ...".
//
// Handlers must return this result alongside a nil error: if a handler
// returns a non-nil error, the SDK itself sets IsError and copies the raw
// error string into Content, which is exactly the leak this helper exists
// to prevent.
func toolErr(err error) *mcp.CallToolResult {
	return mcpx.ToolErr("wakil-ctx", err)
}

func setEnvironment(name string) error {
	if project, environment := wakilcore.PinnedPlace(); project != "" || environment != "" {
		return wakilcore.ErrPinned()
	}
	r, err := wakilcore.Resolve()
	if err != nil {
		return err
	}
	// "" leaves the project with no environment chosen, as a project switch to one lacking the
	// environment does: the place a conversation started with none chosen lives in (workspaces,
	// piece 3 walk — the home opens it there).
	if _, ok := r.Project.Environments[name]; !ok && name != "" {
		return wakilcore.UserError("unknown environment: " + name)
	}
	a, err := wakilcore.ReadActive()
	if err != nil {
		return err
	}
	a.Environment = name
	return wakilcore.WriteActive(a)
}

// setActiveProvider persists the operator's chosen provider (account) as
// active.json's fourth axis (Task 7's ActiveContext.Provider), the write
// half Task 7 deliberately left undone — see that task's own closing
// note. It is Task 9's, not Task 7's or Task 6's: Task 6 only READS
// ActiveProvider to build a harness, and a provider switch that could
// never be recorded to disk would silently revert on every relaunch.
//
// Validated against the org's registered providers (LoadProviderFor)
// BEFORE the write, exactly as setEnvironment validates against the
// project's declared environments before its own write — an id that
// does not name a real provider must never reach active.json at all.
// By the time WindowModel dispatches this (after Task 9's swap has
// already started a harness under `id`'s own credentials), the id is
// known-good; this check exists for the direct, non-UI callers this MCP
// tool is equally reachable from (a hand-typed `--dispatch`, a future
// CLI), which have no harness-start success to lean on as an implicit
// check.
func setActiveProvider(id string) error {
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return err
	}
	if _, err := wakilcore.LoadProviderFor(org, id); err != nil {
		return err
	}
	a, err := wakilcore.ReadActiveUnpinned()
	if err != nil {
		return err
	}
	a.Provider = id
	return wakilcore.WriteActive(a)
}

// OrgSummary is one row of the org plane's Choosing state.
//
// Accounts is a COUNT and never the accounts themselves: this tool is
// reachable with no org set, so it must not become a way to enumerate
// another org's credentials. list_machine_providers is the deliberate,
// operator-only place cross-org provider detail is exposed.
type OrgSummary struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName,omitempty"`
	JiraBase    string `json:"jiraBase,omitempty"`
	Accounts    int    `json:"accounts"`
}

type OrgListing struct {
	Orgs []OrgSummary `json:"orgs"`
}

type createOrgArgs struct {
	ID          string `json:"id" jsonschema:"the new organisation's id"`
	DisplayName string `json:"displayName,omitempty" jsonschema:"optional human-readable name, e.g. \"Initech Labs\""`
	JiraBase    string `json:"jiraBase,omitempty" jsonschema:"optional Atlassian site, absolute https"`
}

// updateOrgArgs is the settings pane's edit of the organisation's three
// strings.
//
// **Every field is a POINTER, and that is the whole shape of the
// read-modify-write rule** (#199). An absent field means "leave whatever
// is on disk"; a field present and empty means "clear it". An operator
// who clears the Jira site means to clear it, and an operator who saves a
// display name has not thereby asked for the other two to be blanked.
// Non-pointer strings cannot express the difference, and the version that
// used them would silently overwrite a hand edit made while the pane was
// open.
// configDirResult wraps the derived path in an object, matching every
// other Out in this file: a bare string Out advertises a non-object
// outputSchema, which is the list_sessions defect schema_test.go exists to
// catch.
type configDirResult struct {
	ConfigDir string `json:"configDir"`
}

type updateOrgArgs struct {
	// ID names the organisation to edit. Required, and NOT defaulted to
	// the active one: this writes across the boundary Invariant 4
	// defines, and a write that guesses which organisation it lands in is
	// a write that can land in the wrong one.
	ID                    string  `json:"id" jsonschema:"the organisation to edit"`
	DisplayName           *string `json:"displayName,omitempty" jsonschema:"optional human-readable name; omit to leave unchanged, send \"\" to clear"`
	JiraBase              *string `json:"jiraBase,omitempty" jsonschema:"optional Atlassian site, absolute https; omit to leave unchanged, send \"\" to clear"`
	DefaultProvider       *string `json:"defaultProvider,omitempty" jsonschema:"optional account id, which must already be registered in this organisation; omit to leave unchanged, send \"\" to clear"`
	SpeechProvider        *string `json:"speechProvider,omitempty" jsonschema:"optional speech engine id (apple); omit to leave unchanged, send \"\" to clear"`
	QuickProvider         *string `json:"quickProvider,omitempty" jsonschema:"optional provider id quick tasks run on; omit to leave unchanged, send \"\" for the active provider"`
	GitName               *string `json:"gitName,omitempty" jsonschema:"author name for commits from Wakil; omit to leave unchanged, send \"\" to clear"`
	GitEmail              *string `json:"gitEmail,omitempty" jsonschema:"author email for commits from Wakil; omit to leave unchanged, send \"\" to clear"`
	GhostText             *bool   `json:"ghostText,omitempty" jsonschema:"ghost-text on or off for this organisation"`
	FastPath              *bool   `json:"fastPath,omitempty" jsonschema:"the composer's fast path on or off for this organisation"`
	CommitDrafts          *bool   `json:"commitDrafts,omitempty" jsonschema:"the commit box's drafted message (✨) on or off for this organisation"`
	ConversationNames     *bool   `json:"conversationNames,omitempty" jsonschema:"naming conversations with the quick model on or off for this organisation"`
	PullStrategy          *string `json:"pullStrategy,omitempty" jsonschema:"how Pull and Sync integrate: rebase, merge or ff-only"`
	AgentGeneral          *string `json:"agentGeneral,omitempty" jsonschema:"the organisation's general agent instructions"`
	GitCommitInstructions *string `json:"gitCommitInstructions,omitempty" jsonschema:"how the agent writes commit messages here"`
	GitPRInstructions     *string `json:"gitPRInstructions,omitempty" jsonschema:"how the agent writes PR titles and descriptions here"`
	GitBranchInstructions *string `json:"gitBranchInstructions,omitempty" jsonschema:"how a workspace's branch is named here"`
	MessageWakes          *int    `json:"messageWakes,omitempty" jsonschema:"Agents woken by messages: message-woken turns per operator message per workspace, 0 to 99 (0 never wakes); -1 clears it back to the default, 8"`
}

type setProjectAgentArgs struct {
	ProjectPath  string  `json:"projectPath" jsonschema:"absolute path to the project.json"`
	General      *string `json:"general,omitempty" jsonschema:"the project's general agent instructions"`
	Commits      *string `json:"commits,omitempty" jsonschema:"the project's commit message instructions"`
	PullRequests *string `json:"pullRequests,omitempty" jsonschema:"the project's PR instructions"`
	Branches     *string `json:"branches,omitempty" jsonschema:"the project's branch naming instructions"`
	MessageWakes *int    `json:"messageWakes,omitempty" jsonschema:"the project's own Agents woken by messages, 0 to 99; -1 clears it back to the organisation's"`
}

type gitSecretArgs struct {
	ID         string `json:"id" jsonschema:"the organisation's id"`
	Host       string `json:"host" jsonschema:"the git host"`
	Comment    string `json:"comment,omitempty" jsonschema:"a generated key's comment"`
	Token      string `json:"token,omitempty" jsonschema:"the token to keep"`
	Passphrase string `json:"passphrase,omitempty" jsonschema:"the picked key's passphrase"`
}

// Added by Connections (Task 2): the operator's own MCP servers for an organisation. Every
// argument set names the organisation in id, as update_org does.
type connectionAddArgs struct {
	ID        string            `json:"id" jsonschema:"the organisation's id"`
	Kind      string            `json:"kind" jsonschema:"a catalog id (github, atlassian, datadog, amplitude, slack) or custom"`
	Name      string            `json:"name,omitempty" jsonschema:"optional; defaults to the kind, then kind-2, kind-3"`
	Transport string            `json:"transport,omitempty" jsonschema:"custom only: stdio or http"`
	URL       string            `json:"url,omitempty" jsonschema:"the address of an http server; a catalog kind has its own"`
	Command   string            `json:"command,omitempty" jsonschema:"the program of a stdio server; a catalog kind has its own"`
	Args      []string          `json:"args,omitempty" jsonschema:"the program's arguments"`
	SignIn    string            `json:"signIn,omitempty" jsonschema:"custom only: token, fields, browser or none (default none)"`
	Values    map[string]string `json:"values,omitempty" jsonschema:"non-secret field values; a secret field goes through connection_secrets_set"`
}

type connectionAddOut struct {
	Name string `json:"name" jsonschema:"the connection's name, as stored"`
}

type connectionUpdateArgs struct {
	ID      string            `json:"id" jsonschema:"the organisation's id"`
	Name    string            `json:"name" jsonschema:"the connection to edit"`
	NewName *string           `json:"newName,omitempty" jsonschema:"optional new name; the Keychain item moves with it"`
	URL     *string           `json:"url,omitempty" jsonschema:"optional address; omit to leave unchanged"`
	Command *string           `json:"command,omitempty" jsonschema:"optional program; omit to leave unchanged"`
	Args    *[]string         `json:"args,omitempty" jsonschema:"optional arguments, the whole list; omit to leave unchanged"`
	Values  map[string]string `json:"values,omitempty" jsonschema:"non-secret field values to set; an empty value clears that field"`
	Hints   map[string]string `json:"hints,omitempty" jsonschema:"the server's word on each tool as it lists them now (readOnly, writes, destructive or empty), the whole list; omit to leave unchanged"`
}

type connectionNameArgs struct {
	ID   string `json:"id" jsonschema:"the organisation's id"`
	Name string `json:"name" jsonschema:"the connection"`
}

type connectionSecretsArgs struct {
	ID     string            `json:"id" jsonschema:"the organisation's id"`
	Name   string            `json:"name" jsonschema:"the connection"`
	Values map[string]string `json:"values" jsonschema:"secret field id to value, kept in the Keychain"`
}

type connectionAllowArgs struct {
	ID    string `json:"id" jsonschema:"the organisation's id"`
	Name  string `json:"name" jsonschema:"the connection"`
	Tool  string `json:"tool" jsonschema:"the server's tool"`
	Allow bool   `json:"allow" jsonschema:"whether the gate lets it through"`
}

type connectionSignInStartOut struct {
	URL string `json:"url" jsonschema:"the sign-in page; the app opens it in the browser"`
}

type connectionSignInWaitOut struct {
	Account string `json:"account" jsonschema:"who the sign-in is for, as the server reports it, else the server's host"`
}

type connectionCatalogOut struct {
	Kinds []wakilcore.ConnectionKind `json:"kinds"`
}

type jiraTokenArgs struct {
	ID    string `json:"id" jsonschema:"the organisation's id"`
	Email string `json:"email" jsonschema:"the Atlassian account's email"`
	Token string `json:"token" jsonschema:"the Atlassian API token"`
}

// refuseSecretValues refuses a value for a field the catalog marks secret: it must never reach
// org.json.
func refuseSecretValues(kind string, values map[string]string) error {
	for _, k := range wakilcore.ConnectionCatalog {
		if k.ID != kind {
			continue
		}
		for _, f := range k.Fields {
			if _, given := values[f.ID]; given && f.Secret {
				return wakilcore.UserError(f.ID + " is a secret: it goes through connection_secrets_set, not into the record")
			}
		}
	}
	return nil
}

type gitDevicePollArgs struct {
	ID         string `json:"id" jsonschema:"the organisation's id"`
	Provider   string `json:"provider" jsonschema:"github or gitlab"`
	Host       string `json:"host" jsonschema:"the host the account is for"`
	DeviceCode string `json:"deviceCode" jsonschema:"git_device_start's deviceCode"`
	APIAccess  bool   `json:"apiAccess,omitempty" jsonschema:"true when the Sign in is an ssh GitHub account's API access: the account keeps ssh"`
}

type gitDevicePollOut struct {
	Pending bool `json:"pending"`
	Done    bool `json:"done"`
}

type gitGhLoginsOut struct {
	Logins []wakilcore.GhLogin `json:"logins"`
}

type gitSSHKeysOut struct {
	Keys []wakilcore.SSHKeyListing `json:"keys"`
}

type gitKeyOut struct {
	PublicKey string `json:"publicKey"`
	Path      string `json:"path"`
}

type gitTestOut struct {
	User string `json:"user"`
}

type gitHostSuggestionsOut struct {
	Hosts []wakilcore.GitHostSuggestion `json:"hosts"`
}

type gitAccountArgs struct {
	ID       string `json:"id" jsonschema:"the organisation's id"`
	Host     string `json:"host" jsonschema:"the git host, e.g. github.com"`
	Provider string `json:"provider,omitempty" jsonschema:"github, gitlab, bitbucket or other"`
	Method   string `json:"method,omitempty" jsonschema:"ssh, token or signin"`
	User     string `json:"user,omitempty" jsonschema:"the account name the host knows"`
	KeyPath  string `json:"keyPath,omitempty" jsonschema:"an ssh account's private key"`
	Username string `json:"username,omitempty" jsonschema:"Bitbucket's username, used with its token"`
}

// gitOrgArgs is what the account sheet's reads take: the organisation, and Sign in's provider.
// No host — they run before one is chosen.
type gitOrgArgs struct {
	ID       string `json:"id" jsonschema:"the organisation's id"`
	Provider string `json:"provider,omitempty" jsonschema:"github or gitlab, for git_device_start"`
}

// setEditorSettingsArgs is the app-wide editor tier's edit (3b-v). Pointers for updateOrgArgs'
// reason: absent leaves what is on disk.
type setEditorSettingsArgs struct {
	FontSize    *int    `json:"fontSize,omitempty" jsonschema:"9 to 24; omit to leave unchanged"`
	WordWrap    *bool   `json:"wordWrap,omitempty" jsonschema:"omit to leave unchanged"`
	Autosave    *string `json:"autosave,omitempty" jsonschema:"off, pause or focus; omit to leave unchanged"`
	ShowIgnored *bool   `json:"showIgnored,omitempty" jsonschema:"false hides gitignored files from the tree and from ⌘P; omit to leave unchanged"`
	InlineBlame *bool   `json:"inlineBlame,omitempty" jsonschema:"false hides who last changed the cursor's line at its end; omit to leave unchanged"`
	GhostText   *bool   `json:"ghostText,omitempty" jsonschema:"false turns AI ghost-text off in every editor and query line; omit to leave unchanged"`
}

// setKeysArgs is the keymap's whole override map; no pointer, because an empty map is a value
// (every default back).
type setKeysArgs struct {
	Keys map[string]string `json:"keys" jsonschema:"command id to chord, or to empty for unbound; replaces every stored override"`
}

// setBrowserSettingsArgs is the app-wide browser setting's edit (3c-i), pointers for the same
// reason as setEditorSettingsArgs.
type setBrowserSettingsArgs struct {
	SearchEngine      *string `json:"searchEngine,omitempty" jsonschema:"google, duckduckgo, bing or kagi; omit to leave unchanged"`
	StartPage         *string `json:"startPage,omitempty" jsonschema:"an http or https URL a new tab opens, or empty for a blank page; omit to leave unchanged"`
	SearchSuggestions *bool   `json:"searchSuggestions,omitempty" jsonschema:"true sends what you type in the address bar to the search engine for suggestions; false (the default) sends nothing until Return; omit to leave unchanged"`
	Tabs              *string `json:"tabs,omitempty" jsonschema:"horizontal or vertical: where the tab strip sits; omit to leave unchanged"`
	NameGroups        *bool   `json:"nameGroups,omitempty" jsonschema:"false stops the model naming automatic tab groups; true (the default) lets it; omit to leave unchanged"`
	PictureInPicture  *bool   `json:"pictureInPicture,omitempty" jsonschema:"true (the default) floats a playing video when you leave its tab; false never does; omit to leave unchanged"`
}

// setProjectEditorSettingsArgs is one project's editor tier's edit (3b-v).
type setProjectPMKeyArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	ProjectKey  string `json:"projectKey" jsonschema:"the project's Jira project key (INI); empty clears it"`
}

type setProjectEditorSettingsArgs struct {
	ProjectPath  string    `json:"projectPath" jsonschema:"absolute path to the project.json"`
	TabSize      *int      `json:"tabSize,omitempty" jsonschema:"1 to 16; omit to leave unchanged"`
	InsertSpaces *bool     `json:"insertSpaces,omitempty" jsonschema:"true indents with spaces, false with tabs; omit to leave unchanged"`
	HeavyFolders *[]string `json:"heavyFolders,omitempty" jsonschema:"folder names, matched at any depth among the folders git ignores, listed but never walked or searched; the whole list, [] for none (.git is always heavy and is not listed); omit to leave unchanged"`
}

// addProviderArgs is the commit half of the add flow (#204).
//
// **No org field**, and that is the ruling rather than an omission: the
// binding is written for the organisation the operator is STANDING IN.
// An org parameter would be a list to choose from, and choosing is what
// adopt_provider is for.
type addProviderArgs struct {
	ID        string `json:"id" jsonschema:"the account id to register"`
	ConfigDir string `json:"configDir" jsonschema:"the config dir the sign-in and the mint used — the same string, resolved once at the derivation"`
	Kind      string `json:"kind,omitempty" jsonschema:"provider kind; defaults to claude-code"`
	Label     string `json:"label,omitempty" jsonschema:"optional human-readable name"`
	// ClaudePath is the agent executable the sign-in and the mint just
	// ran, recorded so the binding can start a session (#259).
	ClaudePath string `json:"claudePath,omitempty" jsonschema:"absolute path to the agent executable this account runs; required for claude-code"`
}

// setLocalProviderArgs creates or overrides the active organisation's local model endpoint
// (3b-viii, Decision 42). No org field, for the same reason addProviderArgs has none.
type setLocalProviderArgs struct {
	ID      string   `json:"id" jsonschema:"the local provider id to create or override"`
	Label   string   `json:"label,omitempty" jsonschema:"optional human-readable name"`
	BaseURL string   `json:"baseURL" jsonschema:"the endpoint's http or https URL, e.g. http://127.0.0.1:8012"`
	Serves  []string `json:"serves,omitempty" jsonschema:"ignored: a local provider serves every quick task"`
}

// unlinkProviderArgs removes one organisation's binding.
//
// `Org` defaults to the active one. Unlike `adopt_provider`, which binds
// an account INTO a named organisation and therefore must be told which,
// an unlink is something an organisation does to its own record — and the
// settings pane only ever unlinks rows it is standing in.
type unlinkProviderArgs struct {
	ID  string `json:"id" jsonschema:"the account id whose binding to remove"`
	Org string `json:"org,omitempty" jsonschema:"the organisation holding the binding; defaults to the active one"`
}

// setDatabaseDSNArgs carries the one secret a human types in this phase.
//
// **It is marked secret-bearing on the Swift side**, so the journal
// records the parameter's NAME and `[redacted]` for its value (#197).
// This is that rule's first caller, and the reason the DSN is the one
// thing in 2e that travels through an action at all: a provider
// credential is minted and stored in Go precisely so nothing does.
type setDatabaseDSNArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment string `json:"environment" jsonschema:"the environment the database belongs to"`
	Name        string `json:"name" jsonschema:"the database's name"`
	Driver      string `json:"driver" jsonschema:"the driver, e.g. mysql"`
	DSN         string `json:"dsn" jsonschema:"the connection string; stored in the Keychain and never written to the project file"`
	GrantWrite  bool   `json:"grantWrite,omitempty" jsonschema:"grant write access, which needs its own second credential"`
	WriteDSN    string `json:"writeDsn,omitempty" jsonschema:"the write credential, required when grantWrite is set"`
}

// setDatabaseConnectionArgs: a database saved as parts. Password and WritePassword are
// secret-bearing (the Swift action redacts them); an empty Password keeps the stored one.
type setDatabaseConnectionArgs struct {
	ProjectPath   string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment   string `json:"environment" jsonschema:"the environment the database belongs to"`
	Name          string `json:"name" jsonschema:"the database's name"`
	Driver        string `json:"driver" jsonschema:"the driver: mysql, mongo or sqlite"`
	Host          string `json:"host,omitempty" jsonschema:"the server's host (not for sqlite)"`
	Port          string `json:"port,omitempty" jsonschema:"the server's port; empty means the driver's default"`
	Database      string `json:"database,omitempty" jsonschema:"the database or schema name"`
	User          string `json:"user,omitempty" jsonschema:"the read login's user"`
	Path          string `json:"path,omitempty" jsonschema:"the file path (sqlite only)"`
	Password      string `json:"password,omitempty" jsonschema:"the read login's password; stored in the Keychain, never written to the project file; empty keeps the stored one"`
	GrantWrite    bool   `json:"grantWrite,omitempty" jsonschema:"grant write access through a second login"`
	WriteUser     string `json:"writeUser,omitempty" jsonschema:"the write login's user, when grantWrite is set"`
	WritePassword string `json:"writePassword,omitempty" jsonschema:"the write login's password; stored in the Keychain; empty keeps the stored one"`
}

type removeDatabaseArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment string `json:"environment" jsonschema:"the environment the database belongs to"`
	Name        string `json:"name" jsonschema:"the database's name"`
}

// setApiEntryArgs: Token is secret-bearing; the Swift action redacts it, so the journal records `[redacted]`.
type setApiEntryArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment string `json:"environment" jsonschema:"the environment the API entry belongs to"`
	Name        string `json:"name" jsonschema:"the API entry's name"`
	BaseURL     string `json:"baseUrl" jsonschema:"the API's base URL"`
	AuthHeader  string `json:"authHeader,omitempty" jsonschema:"the header the token is sent in"`
	Token       string `json:"token,omitempty" jsonschema:"the API token; stored in the Keychain and never written to the project file"`
}

type updateApiEntryArgs struct {
	ProjectPath string  `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment string  `json:"environment" jsonschema:"the environment the API entry belongs to"`
	Name        string  `json:"name" jsonschema:"the API entry's current name"`
	NewName     *string `json:"newName,omitempty" jsonschema:"rename the entry; absent leaves it unchanged"`
	BaseURL     *string `json:"baseUrl,omitempty" jsonschema:"new base URL; absent leaves it unchanged"`
	AuthHeader  *string `json:"authHeader,omitempty" jsonschema:"new auth header; absent leaves it unchanged"`
	ClearToken  bool    `json:"clearToken,omitempty" jsonschema:"drop the entry's token reference; the Keychain item is kept"`
}

type removeApiEntryArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment string `json:"environment" jsonschema:"the environment the API entry belongs to"`
	Name        string `json:"name" jsonschema:"the API entry's name"`
}

type updateDatabaseArgs struct {
	ProjectPath string  `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Environment string  `json:"environment" jsonschema:"the environment the database belongs to"`
	Name        string  `json:"name" jsonschema:"the database's current name"`
	NewName     *string `json:"newName,omitempty" jsonschema:"rename the database; absent leaves it unchanged"`
	RevokeWrite bool    `json:"revokeWrite,omitempty" jsonschema:"make the database read-only again; the write Keychain item is kept"`
}

type createProjectArgs struct {
	Folder string `json:"folder" jsonschema:"absolute path of the folder the project lives in"`
	Name   string `json:"name" jsonschema:"the new project's name"`
}

type createProjectOut struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type renameProjectArgs struct {
	Name    string `json:"name" jsonschema:"the project's current name"`
	NewName string `json:"newName" jsonschema:"the name to give it"`
}

type removeProjectArgs struct {
	Name string `json:"name" jsonschema:"the project to remove from the registry"`
}

type createEnvironmentArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
}

type createEnvironmentOut struct {
	Name string `json:"name"`
}

type renameEnvironmentArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Name        string `json:"name" jsonschema:"the environment's current name"`
	NewName     string `json:"newName" jsonschema:"the name to give it"`
}

type setEnvironmentProductionArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Name        string `json:"name" jsonschema:"the environment"`
	Production  string `json:"production" jsonschema:"yes, no, or name to let the environment's name decide"`
}

type removeEnvironmentArgs struct {
	ProjectPath string `json:"projectPath" jsonschema:"absolute path to the project.json"`
	Name        string `json:"name" jsonschema:"the environment to remove"`
}

type removeEnvironmentOut struct {
	Trashed string `json:"trashed"`
}

// MachineProviderListing wraps []wakilcore.MachineProvider in a
// top-level object, matching OrgListing and wakilcore.ProviderListing:
// a bare slice Out produces a non-object outputSchema (["null","array"]
// at the top level), which is exactly the list_sessions defect
// schema_test.go's TestOutputSchemasAreObjects exists to catch. Never
// nil, for the same reason those two are never nil.
type MachineProviderListing struct {
	Providers []wakilcore.MachineProvider `json:"providers"`
}

// adoptProviderArgs grew FromOrg and FromID in Phase 2e (#201).
//
// **They ADD an argument rather than populating one**, which Decision 32
// carries as a correction: there was no field here for a source binding,
// so nothing could be copied from one. The adoption now reads the source
// organisation's credential and writes the adopting one's — in Go, both
// silent, the service name derived — which is what makes it instant and
// what makes forgetting the second copy impossible. Forgetting it is
// exactly today's defect: `ProviderTokenRef` carries no org, so a shared
// account needs the same token stored twice, and a binding without the
// second one leaves the window refusing to start against a Keychain item
// that does not exist.
//
// No `claudePath` argument is added, deliberately. The path is RESOLVED
// from the source binding rather than passed in — a caller that could
// supply one could supply the wrong one, and the source already knows.
type adoptProviderArgs struct {
	Org       string `json:"org" jsonschema:"the organisation to adopt the account into"`
	ID        string `json:"id" jsonschema:"the provider id to register under that organisation"`
	ConfigDir string `json:"configDir" jsonschema:"an existing config dir already homed by another organisation"`
	Kind      string `json:"kind" jsonschema:"provider kind, e.g. claude-code"`
	FromOrg   string `json:"fromOrg,omitempty" jsonschema:"the organisation whose binding the credential is copied from; omit to copy nothing"`
	FromID    string `json:"fromId,omitempty" jsonschema:"the account id in fromOrg whose credential is copied; omit to copy nothing"`
	Label     string `json:"label,omitempty" jsonschema:"optional human label"`
}

// listOrgs enumerates every registered org. It must never call
// CurrentOrg(): the operator this tool exists to serve is precisely the
// one who has no org, and demanding one would rebuild the dead end the
// org plane was built to end (probe §3).
func listOrgs() (OrgListing, error) {
	ids, err := wakilcore.ListOrgs()
	if err != nil {
		return OrgListing{}, err
	}
	out := OrgListing{Orgs: make([]OrgSummary, 0, len(ids))}
	for _, id := range ids {
		row := OrgSummary{ID: id}
		// Both lookups are best-effort. One unreadable org.json must not
		// blank the whole list — the operator still needs to pick.
		if o, err := wakilcore.LoadOrgFor(id); err == nil {
			row.JiraBase = o.JiraBase
			row.DisplayName = o.DisplayName
		}
		if ps, err := wakilcore.ListProvidersFor(id); err == nil {
			row.Accounts = len(ps)
		}
		out.Orgs = append(out.Orgs, row)
	}
	return out, nil
}

// createOrg wraps CreateOrg and returns its refusal unchanged.
//
// There is deliberately NO defaultProvider parameter. CreateOrg refuses one
// by construction — the id must already name a provider registered under an
// org that does not exist yet (org.go:89-95) — so the field could only ever
// produce an error. Spec §8.3.
func createOrg(a createOrgArgs) error {
	return wakilcore.CreateOrg(a.ID, wakilcore.Org{DisplayName: a.DisplayName, JiraBase: a.JiraBase})
}

// newServer builds the wakil-ctx MCP server with all eleven tools
// registered. Extracted from main so handlers are reachable from tests.
func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-ctx", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "get_context", Description: "Show the active org, project, roots, environment, scopes, and the provider report (which provider the active project prefers versus which one is actually running)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, *wakilcore.Resolved, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				// The error is still an error — but it carries what IS
				// knowable. See PartialResolved's doc comment.
				return toolErr(err), wakilcore.PartialResolved(), nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_projects", Description: "List projects in the active organization, with any misfiled or unreadable entries named."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.ProjectListing, error) {
			out, err := wakilcore.ListProjectsForOrg()
			if err != nil {
				return toolErr(err), wakilcore.ProjectListing{Projects: map[string]wakilcore.ProjectEntry{}}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_project", Description: "Switch the active project (must belong to the active org)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a nameArg) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetProjectChecked(a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_environment", Description: "Switch the active environment within the active project; an empty name leaves none chosen."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a nameArg) (*mcp.CallToolResult, empty, error) {
			if err := setEnvironment(a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_environments", Description: "List the active project's environments under an environments key, each carrying readOnly and production. readOnly is true only when nothing in the environment is configured for writing — no database carries a write credential and no API entry is declared; an environment declaring nothing reports true vacuously, so it is never evidence that an environment IS configured. production is what Wakil will treat the environment as: the environment's own production flag when it declares one, and otherwise whether it is named exactly \"production\". Do not re-derive it from the name — an environment named prod is not production unless it says so, and one named production can declare that it is not. A notices array names configurations a reader would misread, and is empty when there are none."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.EnvironmentList, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				return toolErr(err), wakilcore.NewEnvironmentList(nil), nil
			}
			return nil, wakilcore.NewEnvironmentList(r.Project.Environments), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_sessions", Description: "List Claude Code sessions for the active project's roots across every provider the active org holds, newest first, under a sessions key. Each session carries the provider it was found under, its working directory (cwd), an optional title (the transcript's latest ai-title record, when the CLI wrote one), and an optional parent (the session id it was forked from, per the org's lineage store, when one was recorded). The skipped field is omitted entirely when zero and present otherwise; a non-zero value counts transcript directories or files this search could not read (permissions, or a race against Claude Code), so an empty sessions array with a non-zero skipped means \"could not look\", not \"none exist\". The unreadProviders field, likewise omitted when empty, names providers whose stores could not be looked inside: those that name no readable store (a kind with no session adapter, meaning codex or local, or a claude-code record with no configDir), those whose transcript store exists but could not be read, and those whose provider record could not be parsed. A provider that has simply never run a session is not listed there — its empty answer is known, not unknown."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.SessionList, error) {
			out, err := wakilcore.ListSessions()
			if err != nil {
				return toolErr(err), wakilcore.NewSessionList(nil, 0, nil), nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "get_session", Description: "Get metadata and first prompt for one session: its provider, working directory (cwd), an optional title (the transcript's latest ai-title record, when the CLI wrote one), and an optional parent (the session id it was forked from, per the org's lineage store, when one was recorded)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a idArg) (*mcp.CallToolResult, wakilcore.SessionMeta, error) {
			out, err := wakilcore.GetSession(a.ID)
			if err != nil {
				return toolErr(err), wakilcore.SessionMeta{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "read_session", Description: "Read one session's transcript as thought-thread entries, oldest first, together with the working directory it ran in, the provider holding it and the session it was forked from. Keeps the last limit entries and sets truncated when earlier ones were dropped. thinking blocks produce no entry. Refuses, naming the directory, when the session's working directory is not a root of the active project — resuming it elsewhere would leave the transcript describing two places at once."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a readSessionArgs) (*mcp.CallToolResult, wakilcore.SessionThread, error) {
			out, err := wakilcore.ReadSession(a.ID, a.Limit)
			if err != nil {
				return toolErr(err), wakilcore.NewErrSessionThread(), nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "record_session_parent", Description: "Record that one session was forked from another, in the active org's lineage store. The CLI records no such link, so this is the only place it lives; the session list reports it so a chain of resumes can be shown as one conversation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a sessionParentArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RecordSessionParent(a.Child, a.Parent); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "record_capacity", Description: "Record how much of a claude-code provider's 5-hour and weekly windows is left (or the monthly one when an account has no 5-hour window), as the window read it from the agent's own stream. Keyed by the account's config dir, so an account shared by two organisations reads the same in both. A reading older than the stored one is ignored."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recordCapacityArgs) (*mcp.CallToolResult, empty, error) {
			org, err := wakilcore.CurrentOrg()
			if err == nil {
				err = wakilcore.RecordCapacity(org, a.Provider, wakilcore.CapacityRecord{FiveHour: a.FiveHour, SevenDay: a.SevenDay, Month: a.Month, AsOf: a.AsOf})
			}
			if err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "capacity", Description: "How much of each provider's 5-hour and weekly rate-limit window is left (or the monthly one when an account has no 5-hour window) in the active organisation, with each window's reset time and when it was read. state is read, notRead (no session has run on it in Wakil), noLimits (a local model) or error (that account alone could not be read). With refresh, stale claude-code accounts are probed first (one 1-token request each)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a capacityArgs) (*mcp.CallToolResult, wakilcore.CapacityListing, error) {
			out, err := wakilcore.ReadCapacityForCurrentOrg(a.Refresh)
			if err != nil {
				return toolErr(err), wakilcore.CapacityListing{Readings: []wakilcore.CapacityReading{}}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_provider", Description: "Persist the operator's chosen provider (account) as the active context's fourth axis (active.json), independent of the active project and environment. Refuses an id that does not name a provider already registered in the active org."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a nameArg) (*mcp.CallToolResult, empty, error) {
			if err := setActiveProvider(a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// Added by Phase 2b-vi Task 12: acceptance found that nothing exposed
	// the active org's registered providers to the app at all, so its
	// picker had a switch (`set_provider`) with no list to choose from.
	// Deliberately the id, kind and label only — never configDir,
	// claudePath, or (above all) the credential; see ProviderSummary's own
	// doc comment for why that is structural rather than a promise this
	// handler has to keep by hand.
	mcp.AddTool(s, &mcp.Tool{Name: "list_providers", Description: "List the providers (accounts) registered in the active organization: each one's id, kind, and label when it has one. Never a credential — that comes back only from `wakil provider credentials`, and only for the one provider actually being switched to."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.ProviderListing, error) {
			out, err := wakilcore.ListProvidersForCurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.ProviderListing{Providers: []wakilcore.ProviderSummary{}}, nil
			}
			return nil, out, nil
		})

	// Added by Phase 2e (#198): the settings pane's one read. It answers
	// the WHOLE of the active organisation's configuration in one call —
	// the three org strings, the providers it has registered, and every
	// project with every environment's databases and API — because the
	// pane caches nothing at all and re-reads disk on open and on every
	// read. Assembling the same tree from list_projects plus one
	// list_environments per project would be N+1 round trips to answer a
	// question one file walk answers, and would give the pane no way to
	// report a project it could not read.
	//
	// Never a credential, and structurally so: nothing on wakilcore's
	// ConfigTree types reads the Keychain. A database's REF travels —
	// that is a Keychain entry NAME, and the operator's own settings pane
	// is exactly where one is worth reading — and its value does not.
	mcp.AddTool(s, &mcp.Tool{Name: "config_tree", Description: "Read the active organisation's whole configuration as the settings pane draws it: the organisation's display name, Jira site and default provider; the providers (accounts) it has registered; and every project with its roots, scopes and environments, each environment carrying its databases and its API entry. Four levels deep, because an ENVIRONMENT holds the databases and the API, not a project; providers sit beside the projects because a binding is (organisation, provider id) and cannot nest under one. Projects that could not be read, and those whose project.json declares another organisation, are NAMED rather than dropped. Never returns a credential's value — a database's Keychain entry name travels, the secret it names does not."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a configTreeArgs) (*mcp.CallToolResult, wakilcore.ConfigTree, error) {
			out, err := configTreeFor(a.ID)
			if err != nil {
				return toolErr(err), out, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_orgs", Description: "List every organisation registered on this machine: id, Jira site when it has one, and how many accounts it holds. Answers with no active organisation set, which is what makes it usable by an operator who has not chosen one yet. Never returns a credential."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, OrgListing, error) {
			out, err := listOrgs()
			if err != nil {
				return toolErr(err), OrgListing{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "create_org", Description: "Create a new organisation. The display name and Jira site are both optional; an organisation without a display name falls back to showing its id, and one without a Jira site simply has no Jira scope. Refuses to overwrite an existing organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a createOrgArgs) (*mcp.CallToolResult, empty, error) {
			if err := createOrg(a); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// Added by Phase 2e (#199): the settings pane's thinnest complete
	// edit, and the one built first for exactly that reason — it proves
	// the whole path (pane form, .control action, this writer, disk,
	// re-read) before anything credential-bearing travels it.
	//
	// **Read-modify-write from disk at dispatch, never a flush of cached
	// pane state.** The pointer fields are what make that expressible;
	// see updateOrgArgs. Validation and normalisation are unchanged —
	// wakilcore.UpdateOrg goes through normaliseOrg, so a value typed
	// into the pane and one typed at the shell are refused identically,
	// including a defaultProvider naming no registered account.
	mcp.AddTool(s, &mcp.Tool{Name: "update_org", Description: "Change an organisation's display name, Jira site, default account or speech engine, leaving every other field on disk exactly as it is. Read-modify-write: omit a field to leave it unchanged, or send an empty string to clear it — so an edit made to the file by hand while a pane was open survives a save of a different field. Refuses a Jira site that is not an absolute https Atlassian URL, and a default account that is not already registered in this organisation. Refuses an organisation that does not exist; creating one is create_org."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a updateOrgArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.UpdateOrg(a.ID, wakilcore.OrgPatch{
				DisplayName:           a.DisplayName,
				JiraBase:              a.JiraBase,
				DefaultProvider:       a.DefaultProvider,
				SpeechProvider:        a.SpeechProvider,
				QuickProvider:         a.QuickProvider,
				GitName:               a.GitName,
				GitEmail:              a.GitEmail,
				GhostText:             a.GhostText,
				FastPath:              a.FastPath,
				CommitDrafts:          a.CommitDrafts,
				ConversationNames:     a.ConversationNames,
				PullStrategy:          a.PullStrategy,
				AgentGeneral:          a.AgentGeneral,
				GitCommitInstructions: a.GitCommitInstructions,
				GitPRInstructions:     a.GitPRInstructions,
				GitBranchInstructions: a.GitBranchInstructions,
				MessageWakes:          a.MessageWakes,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// Added by 3b-v (Decision 38): the editor's settings, in two tiers. The read is the agent's
	// as much as the operator's; the two writes are operator-only on the Swift side
	// (Decision 30), and read-modify-write from disk here.
	registerRecipeTools(s)
	registerRecipeRunTools(s)
	registerRecipeTryJobTools(s)

	mcp.AddTool(s, &mcp.Tool{Name: "editor_settings", Description: "Read the editor settings in force: font size, word wrap, autosave (off, pause or focus) and whether gitignored files are shown, from the operator's app-wide settings; tab size, tabs-or-spaces and the heavy folders (.git is always heavy besides) from the active project. Defaults fill anything unset. appError carries settings.json's error, whole, when it cannot be read; the defaults are then in force."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.EditorSettings, error) {
			return nil, wakilcore.LoadEditorSettings(), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_editor_settings", Description: "Change the app-wide editor settings: font size (9 to 24), word wrap, autosave (off, pause or focus), showIgnored. Read-modify-write: omit a field to leave it unchanged. Refuses an out-of-range value, and refuses to write over a settings.json that does not parse."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setEditorSettingsArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.UpdateEditorAppSettings(wakilcore.EditorAppPatch{
				FontSize: a.FontSize, WordWrap: a.WordWrap, Autosave: a.Autosave, ShowIgnored: a.ShowIgnored, GhostText: a.GhostText, InlineBlame: a.InlineBlame,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// Added by 3c-i: the browser's app-wide setting, beside the editor's in settings.json. The
	// read is the agent's as much as the operator's; the write is operator-only on the Swift side.
	mcp.AddTool(s, &mcp.Tool{Name: "browser_settings", Description: "Read the browser settings in force: the search engine the address bar uses for words that are not a URL (google, duckduckgo, bing or kagi) and the start page a new tab opens (empty is blank), searchSuggestions (true or false; off by default), tabs (horizontal or vertical), nameGroups (true or false; on by default), and pictureInPicture (true or false; on by default — a playing video floats when you leave its tab). Defaults fill anything unset. appError carries settings.json's error, whole, when it cannot be read; the defaults are then in force."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.BrowserSettings, error) {
			v, _ := wakilcore.ReadBrowserSettings()
			return nil, v, nil
		})

	// The keymap's overrides, beside the other app-wide settings in settings.json. The Swift
	// keymap owns the ids, the defaults and the conflict rules; Go stores the map and checks only
	// that each chord is well formed.
	mcp.AddTool(s, &mcp.Tool{Name: "keyboard", Description: "Read the keyboard overrides: keys maps a command id to its chord (a modifier run in the order ⌃⌥⇧⌘ then one key, such as ⌃⌘W), or to empty when the command is unbound. A command absent from keys keeps its default. appError carries settings.json's error, whole, when it cannot be read; keys is then empty."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.KeyboardSettings, error) {
			keys, appError := wakilcore.ReadKeys()
			return nil, wakilcore.KeyboardSettings{Keys: keys, AppError: appError}, nil
		})

	// Added by 3d-i (Ruling 17): the active organisation's open pull requests, read only. It takes
	// no organisation and returns no credential.
	mcp.AddTool(s, &mcp.Tool{Name: "github_pull_requests", Description: "Read the active organisation's open GitHub pull requests: those it wrote (reason author) and those awaiting its review (reason review-requested), newest update first, from the organisation's GitHub account (github.com first). absent says why there is no list (no GitHub account, an SSH account, no token kept); a refusal or an unreachable host is an error. Read only; no credential is returned."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.PullRequestsResult, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.PullRequestsResult{PullRequests: []wakilcore.MyPullRequest{}}, nil
			}
			out, err := wakilcore.GitHubPullRequests(ctx, org)
			if err != nil {
				return toolErr(err), wakilcore.PullRequestsResult{PullRequests: []wakilcore.MyPullRequest{}}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_browser_settings", Description: "Change the app-wide browser settings: searchEngine (google, duckduckgo, bing or kagi), startPage (an http or https URL, or empty for a blank page), searchSuggestions (true or false; off by default), tabs (horizontal or vertical), nameGroups (true or false; on by default), and pictureInPicture (true or false; on by default — a playing video floats when you leave its tab). Read-modify-write: omit a field to leave it unchanged. Refuses an unknown engine, a tabs value other than horizontal or vertical, or a start page that is not an http or https URL, and refuses to write over a settings.json that does not parse."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setBrowserSettingsArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.WriteBrowserSettings(wakilcore.BrowserSettingsPatch{SearchEngine: a.SearchEngine, StartPage: a.StartPage, SearchSuggestions: a.SearchSuggestions, Tabs: a.Tabs, NameGroups: a.NameGroups, PictureInPicture: a.PictureInPicture}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_keys", Description: "Replace the whole keyboard override map: keys maps a command id to its chord (a modifier run in the order ⌃⌥⇧⌘ then one key — a character, ↩ Tab Space Esc ⌫ ↑ ↓ ← →, or F1 to F19) or to empty for unbound. Whatever was stored before is dropped, so send every override. Refuses a malformed chord, naming the id and chord, and refuses to write over a settings.json that does not parse."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setKeysArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.WriteKeys(a.Keys); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_project_editor_settings", Description: "Change one project's editor settings: tab size (1 to 16), whether to indent with spaces, and the heavy folders (the whole list; each a folder name — no /, not . or .., not .git, no duplicates). Written to the project's project.json, read-modify-write; omit a field to leave it unchanged. A file's own indentation still wins in the editor. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setProjectEditorSettingsArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.UpdateProjectEditorSettings(a.ProjectPath, wakilcore.EditorProjectPatch{
				TabSize: a.TabSize, InsertSpaces: a.InsertSpaces, HeavyFolders: a.HeavyFolders,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_project_pm_key", Description: "Set one project's Jira project (scopes.pm.projectKey, provider jira): the key is trimmed and upper-cased and must be a Jira project key (a letter, then letters, digits or _); empty clears it. Written to the project's project.json, read-modify-write. A project's Ticket tab, its ⌘P tickets and recall scope by it. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setProjectPMKeyArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetProjectPMKey(a.ProjectPath, a.ProjectKey); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// Added by Phase 2e (#200): the settings pane's account table. It is
	// `list_machine_providers` plus the two things that make a row
	// actionable — whether this organisation actually HOLDS the
	// credential, and whether the sign-in is live — and it is a second
	// tool rather than a widening of that one because those two cost a
	// Keychain lookup and a CLI spawn per row, which `get_context`'s
	// callers must not pay.
	//
	// **Presence-only, and structurally so.** wakilcore.CredentialPresence
	// has no field a secret could travel in, and the lookup behind it runs
	// `security` without `-w` and without `-g`, so nothing is read and no
	// access prompt is raised.
	//
	// **Liveness describes the SIGN-IN, not the minted token**, and is read
	// with CLAUDE_CODE_OAUTH_TOKEN absent — without which it reports every
	// account alive, always (measured 2026-09-22).
	//
	// Operator-only on the same reasoning as list_machine_providers: a
	// session scoped to one organisation has no business enumerating every
	// account and config dir on the machine.
	// Added by Phase 2e (#202). **The one-string rule lives here**: the
	// pane spawns a login BEFORE any record exists, so the string it hands
	// to CLAUDE_CONFIG_DIR and the string an AddProvider later stores must
	// be the same one. The CLI hashes the literal string it is given to
	// name its Keychain item and does not resolve symlinks, so a spawn
	// handed the unresolved derivation plus a record storing the resolved
	// one gives Go a name the login never wrote to — a fresh, correct
	// sign-in that reads as logged out. Resolve once, here.
	//
	// Creating the directory is belt-and-braces rather than a requirement:
	// the CLI mkdirs it recursively itself, and the first liveness read of
	// a derived-but-unused directory creates its scaffolding before
	// answering.
	mcp.AddTool(s, &mcp.Tool{Name: "derive_config_dir", Description: "Derive the config directory an account id uses — one directory per id, a pure function of it, so the operator never types or sees a path and re-adding the same id finds the sign-in already there. The path is resolved ONCE here, and the same string must then be used for the spawn, the record and the Keychain name: the CLI hashes the literal string it is handed and does not resolve symlinks, so two spellings of one directory are two different credentials to it. Creates the directory if it is absent, which is belt-and-braces — the CLI creates it itself."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a idArg) (*mcp.CallToolResult, configDirResult, error) {
			dir, err := wakilcore.EnsureConfigDir(a.ID)
			if err != nil {
				return toolErr(err), configDirResult{}, nil
			}
			return nil, configDirResult{ConfigDir: dir}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_accounts", Description: "Every account registered anywhere on this machine, as one flat table with kind as a column: the organisation holding the binding, the account id, its kind and label, its config dir, the organisation that homes that directory, and whether the binding belongs to the active organisation. Each row also carries its credential's Keychain entry NAME and whether an item exists at it — never the value, which is not read — and the entry's modification date, from which the minted token's 365-day clock runs. And each row carries liveness, which describes the operator's SIGN-IN and not the minted token: a directory whose sign-in has lapsed still launches sessions. Liveness is read with the OAuth-token environment variable absent, because the CLI reports a token's PRESENCE rather than validating it. An organisation whose records could not be read is named under skipped rather than dropped. Never returns a credential's value."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.AccountListing, error) {
			out, err := wakilcore.ListAccounts()
			if err != nil {
				return toolErr(err), wakilcore.AccountListing{Accounts: []wakilcore.Account{}}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_machine_providers", Description: "List every account registered anywhere on this machine, as (org, provider) pairs with the config dir and the organisation that homes it. Never returns a credential. Reachable with no active organisation set."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, MachineProviderListing, error) {
			out, err := wakilcore.ListAllProviders()
			if err != nil {
				return toolErr(err), MachineProviderListing{Providers: []wakilcore.MachineProvider{}}, nil
			}
			return nil, MachineProviderListing{Providers: out}, nil
		})

	// **Its description changed in Phase 2e (#201), and the sentence that
	// went is "no credential is created or copied."** That was true and
	// was the defect: a shared account needs the same token stored twice,
	// once per organisation, and an adoption that copied nothing left a
	// binding the window refuses to start under. It copies now, silently,
	// in Go.
	// Added by Phase 2e (#204). **The commit, and it comes AFTER the
	// mint** — which is what makes today's orphaned bindings
	// unreproducible by construction: no record exists until a credential
	// does, so the state where a binding names an account whose Keychain
	// item was never written cannot be reached through this door.
	//
	// **No orgs[], and no choosing.** It writes ONE record, for the
	// organisation the operator is standing in. Another organisation
	// adopts the same account later from its own pane, which is
	// adopt_provider and is a different gesture with a different cost.
	//
	// It REFUSES when the credential is not there, which is the whole of
	// "mint before record" stated as a check rather than as an ordering
	// convention a later caller could get wrong.
	mcp.AddTool(s, &mcp.Tool{Name: "add_provider", Description: "Write the binding for an account that has just been minted, for the ACTIVE organisation and no other — there is no list of organisations and no choosing. Refuses unless a credential is already stored for it: the record is written after the mint, never before, so a binding that names an account with no credential cannot be created this way. Returns the new row with its credential presence and its sign-in liveness."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a addProviderArgs) (*mcp.CallToolResult, wakilcore.Account, error) {
			row, err := wakilcore.CommitMintedProvider(
				a.ID, a.ConfigDir, a.Kind, a.Label, a.ClaudePath)
			if err != nil {
				return toolErr(err), wakilcore.Account{}, nil
			}
			return nil, row, nil
		})

	// Added by 3b-viii (Decision 42): an upsert, because an operator points the one local
	// endpoint somewhere else far more often than they add a second.
	mcp.AddTool(s, &mcp.Tool{Name: "set_local_provider", Description: "Create or override a local model endpoint for the ACTIVE organisation: its id, optional label and baseURL (http or https); a local provider serves every quick task. Refuses a bad URL and an id that is already another kind of account. Returns the provider's config_tree row."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setLocalProviderArgs) (*mcp.CallToolResult, wakilcore.ConfigTreeProvider, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.ConfigTreeProvider{}, nil
			}
			if err := wakilcore.SetLocalProvider(org, wakilcore.Provider{
				ID: a.ID, Label: a.Label, BaseURL: a.BaseURL,
			}); err != nil {
				return toolErr(err), wakilcore.ConfigTreeProvider{}, nil
			}
			tree, err := wakilcore.LoadConfigTreeFor(org)
			if err != nil {
				return toolErr(err), wakilcore.ConfigTreeProvider{}, nil
			}
			for _, p := range tree.Providers {
				if p.ID == a.ID {
					return nil, p, nil
				}
			}
			return toolErr(wakilcore.UserError("provider " + a.ID + " was written but is not in the config tree")), wakilcore.ConfigTreeProvider{}, nil
		})

	// Added by Phase 2e (#206). **An organisation unlinks a BINDING; it
	// never removes a provider** (Decision 32). The record and the
	// Keychain item are both per-(org, id); the ACCOUNT is the config
	// directory, and one account on this machine carries four different
	// ids across four organisations.
	//
	// It never refuses. `remove_provider`'s refusal rests on a claim
	// measured false — what it guarded is one optional field, and the fix
	// landed in the ADD path (#201).
	mcp.AddTool(s, &mcp.Tool{Name: "unlink_provider", Description: "Remove one organisation's binding to an account. Deletes three things, all of them that organisation's own: the record, its Keychain item, and every stale pointer to the gone account — after a removal the organisation file still names it and then refuses to be written at all, so clearing that is not housekeeping. Backfills any sharing record that was inheriting from this one BEFORE deleting it, so nothing is stranded. Never refuses, and never touches the config directory: the Keychain item's name is derived from that path, so deleting the directory would make the name uncomputable. Reports whether this was the last binding to the account — the sole case where revoking is even offered — and always states that Wakil cannot destroy the long-lived credential it created."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a unlinkProviderArgs) (*mcp.CallToolResult, wakilcore.UnlinkOutcome, error) {
			org := a.Org
			if org == "" {
				current, err := wakilcore.CurrentOrg()
				if err != nil {
					return toolErr(err), wakilcore.UnlinkOutcome{}, nil
				}
				org = current
			}
			outcome, err := wakilcore.UnlinkProvider(org, a.ID)
			if err != nil {
				return toolErr(err), outcome, nil
			}
			return nil, outcome, nil
		})

	// Added by Phase 2e (#207). **The DSN goes to the Keychain and the
	// project file gets the REF** — a Keychain entry name, not a secret.
	// That split is why a config file can be read, copied and hand-edited
	// at all.
	//
	// The write is read-modify-write from disk at dispatch, through the
	// product's FIRST `project.json` writer: that file has had no writer
	// until now and the runbooks hand-author it in full, which is why this
	// phase's one owed Go test is about it.
	mcp.AddTool(s, &mcp.Tool{Name: "set_database_dsn", Description: "Store a database's connection string and record the database in an environment. The connection string goes to the Keychain; what lands in the project file is the database's name, driver and the Keychain entry NAME. The ref is derived, never typed. Read-modify-write from disk, so a file edited by hand meanwhile keeps everything this write does not touch — though keys this build does not know about are dropped. Granting write access is a separate, deliberate parameter needing its own second credential, because write authority is proven to the database server rather than asserted. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setDatabaseDSNArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetDatabaseDSN(wakilcore.DatabaseDSNRequest{
				ProjectPath: a.ProjectPath, Environment: a.Environment, Name: a.Name,
				Driver: a.Driver, DSN: a.DSN,
				GrantWrite: a.GrantWrite, WriteDSN: a.WriteDSN,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_database_connection", Description: "Save a database as its parts (host, port, database, user, or a path for sqlite) and record it in an environment. Only the password goes to the Keychain; the parts themselves are written to the project file, and passwords are never returned. An empty password keeps the one already stored. Granting write access is a separate parameter with its own login (writeUser, writePassword). Read-modify-write from disk. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setDatabaseConnectionArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetDatabaseConnection(wakilcore.DatabaseConnectionRequest{
				ProjectPath: a.ProjectPath, Environment: a.Environment, Name: a.Name, Driver: a.Driver,
				Connection: wakilcore.DatabaseConnection{
					Host: a.Host, Port: a.Port, Database: a.Database, User: a.User, Path: a.Path,
					WriteUser: a.WriteUser,
				},
				Password: a.Password, GrantWrite: a.GrantWrite, WritePassword: a.WritePassword,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// **Removing a database KEEPS its Keychain entry** — "unreferenced" is
	// a claim the registry has no standing to make.
	mcp.AddTool(s, &mcp.Tool{Name: "remove_database", Description: "Drop a database from an environment. Its Keychain entry is KEPT: the same credential may be named by another project, a script, or a colleague's checkout, none of which this file can see, so \"unreferenced\" is not something the registry can claim. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a removeDatabaseArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RemoveDatabase(a.ProjectPath, a.Environment, a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_api_entry", Description: "Add an API entry to an environment, or replace the one of that name. The token, if given, goes to the Keychain and never to project.json; the project file keeps only the entry's name, base URL, auth header and the Keychain entry NAME. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setApiEntryArgs) (*mcp.CallToolResult, empty, error) {
			err := wakilcore.SetApiEntry(wakilcore.ApiEntryRequest{
				ProjectPath: a.ProjectPath, Environment: a.Environment, Name: a.Name,
				BaseURL: a.BaseURL, AuthHeader: a.AuthHeader, Token: a.Token,
			})
			if err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "update_api_entry", Description: "Edit an API entry: rename it, change its base URL or auth header, or clear its token reference. An argument left out means unchanged. Clearing the token KEEPS its Keychain item, which another project or script may name. A token is never read back or echoed. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a updateApiEntryArgs) (*mcp.CallToolResult, empty, error) {
			err := wakilcore.UpdateApiEntry(a.ProjectPath, a.Environment, a.Name, wakilcore.ApiEntryEdit{
				NewName: a.NewName, BaseURL: a.BaseURL, AuthHeader: a.AuthHeader, ClearToken: a.ClearToken,
			})
			if err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "remove_api_entry", Description: "Drop an API entry from an environment. Its Keychain item is KEPT: another project, a script or a colleague's checkout may name the same credential. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a removeApiEntryArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RemoveApiEntry(a.ProjectPath, a.Environment, a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "update_database", Description: "Edit a database without re-entering its connection string: rename it (its Keychain references are kept) or revoke write access so it is read-only again. An argument left out means unchanged. Revoking write KEEPS the write Keychain item. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a updateDatabaseArgs) (*mcp.CallToolResult, empty, error) {
			err := wakilcore.UpdateDatabase(a.ProjectPath, a.Environment, a.Name, wakilcore.DatabaseEdit{
				NewName: a.NewName, RevokeWrite: a.RevokeWrite,
			})
			if err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_account_add", Description: "Record an organisation's git account for one host, replacing the one it has there. method is ssh (keyPath), token or signin; the secret goes through its own tool."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitAccountArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.AddGitAccount(a.ID, wakilcore.GitAccount{
				Host: a.Host, Provider: a.Provider, Method: a.Method, User: a.User, KeyPath: a.KeyPath, Username: a.Username,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_host_suggestions", Description: "The hosts an organisation's project roots push to (each origin, ssh aliases resolved), the most used first, with how many roots use each. Read when an account is being added."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitOrgArgs) (*mcp.CallToolResult, gitHostSuggestionsOut, error) {
			return nil, gitHostSuggestionsOut{Hosts: wakilcore.GitHostSuggestions(a.ID)}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_ssh_keys", Description: "The key pairs in ~/.ssh, by their public half's comment, and which need a passphrase."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitOrgArgs) (*mcp.CallToolResult, gitSSHKeysOut, error) {
			return nil, gitSSHKeysOut{Keys: wakilcore.ListSSHKeys()}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_key_generate", Description: "Generate an ed25519 key for an organisation's account on one host, under the organisation's own folder; its passphrase goes to the Keychain. Answers the public key and the private key's path."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitSecretArgs) (*mcp.CallToolResult, gitKeyOut, error) {
			pub, path, err := wakilcore.GenerateGitKey(a.ID, a.Host, a.Comment)
			if err != nil {
				return toolErr(err), gitKeyOut{}, nil
			}
			return nil, gitKeyOut{PublicKey: pub, Path: path}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_token_set", Description: "Keep an organisation's token for one host in the Keychain."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitSecretArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetGitToken(a.ID, a.Host, a.Token); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_api_access_token_set", Description: "Give an organisation's ssh GitHub account API access with an access token, kept at the account's token ref in the Keychain. The account keeps ssh."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitSecretArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetGitAPIAccessToken(a.ID, a.Host, a.Token); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_api_access_remove", Description: "Drop an ssh GitHub account's API access: its token leaves the Keychain and the account stays."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitAccountArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RemoveGitAPIAccess(a.ID, a.Host); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_api_access_test", Description: "Ask GitHub who an ssh account's API access token belongs to. Answers the name, or GitHub's refusal."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitAccountArgs) (*mcp.CallToolResult, gitTestOut, error) {
			user, err := wakilcore.TestGitAPIAccess(ctx, a.ID, a.Host)
			if err != nil {
				return toolErr(err), gitTestOut{}, nil
			}
			return nil, gitTestOut{User: user}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_catalog", Description: "The ready-made connections an operator can pick from: id, title, transport, address, sign-in and the fields each asks for (a secret field is marked; its value is never here)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, connectionCatalogOut, error) {
			return nil, connectionCatalogOut{Kinds: wakilcore.ConnectionCatalog}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_add", Description: "Add one of an organisation's own MCP servers behind Wakil's gate. A catalog kind fills transport, address, command and sign-in itself; custom needs a transport and a url (http) or a command (stdio). Answers the name it was stored under."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionAddArgs) (*mcp.CallToolResult, connectionAddOut, error) {
			c := wakilcore.MCPConnection{Name: a.Name, Kind: a.Kind, URL: a.URL, Command: a.Command, Args: a.Args}
			if err := refuseSecretValues(a.Kind, a.Values); err != nil {
				return toolErr(err), connectionAddOut{}, nil
			}
			if len(a.Values) > 0 {
				c.Values = a.Values
			}
			if a.Kind == "custom" {
				c.Transport, c.SignIn = a.Transport, a.SignIn
				if c.SignIn == "" {
					c.SignIn = "none"
				}
				if c.Transport == "" {
					return toolErr(wakilcore.UserError("a custom connection needs a transport, stdio or http")), connectionAddOut{}, nil
				}
				if c.URL == "" && c.Command == "" {
					return toolErr(wakilcore.UserError("a custom connection needs a url or a command")), connectionAddOut{}, nil
				}
			} else {
				var kind *wakilcore.ConnectionKind
				for i := range wakilcore.ConnectionCatalog {
					if wakilcore.ConnectionCatalog[i].ID == a.Kind {
						kind = &wakilcore.ConnectionCatalog[i]
					}
				}
				if kind == nil {
					return toolErr(wakilcore.UserError("unknown connection kind " + a.Kind)), connectionAddOut{}, nil
				}
				c.Transport, c.SignIn = kind.Transport, kind.SignIn
				if c.URL == "" {
					c.URL = kind.URL
				}
				if c.Command == "" {
					c.Command = kind.Command
				}
				if len(c.Args) == 0 {
					c.Args = kind.Args
				}
			}
			added, err := wakilcore.AddConnection(a.ID, c)
			if err != nil {
				return toolErr(err), connectionAddOut{}, nil
			}
			return nil, connectionAddOut{Name: added.Name}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_update", Description: "Change a connection's name, address, command, arguments, non-secret field values or recorded tool hints, leaving the rest as it is. A rename moves its Keychain item. A secret field is refused here: it goes through connection_secrets_set."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionUpdateArgs) (*mcp.CallToolResult, empty, error) {
			c, ok := wakilcore.ConnectionFor(a.ID, a.Name)
			if !ok {
				return toolErr(wakilcore.UserError("no connection " + a.Name + " in " + a.ID)), empty{}, nil
			}
			if err := refuseSecretValues(c.Kind, a.Values); err != nil {
				return toolErr(err), empty{}, nil
			}
			if err := wakilcore.UpdateConnection(a.ID, a.Name, func(c *wakilcore.MCPConnection) {
				if a.NewName != nil {
					c.Name = *a.NewName
				}
				if a.URL != nil {
					c.URL = *a.URL
				}
				if a.Command != nil {
					c.Command = *a.Command
				}
				if a.Args != nil {
					c.Args = *a.Args
				}
				if a.Hints != nil {
					c.Hints = map[string]string{}
					for k, v := range a.Hints {
						c.Hints[k] = v
					}
				}
				for k, v := range a.Values {
					if v == "" {
						delete(c.Values, k)
						continue
					}
					if c.Values == nil {
						c.Values = map[string]string{}
					}
					c.Values[k] = v
				}
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_remove", Description: "Forget a connection and delete its Keychain item."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionNameArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RemoveConnection(a.ID, a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_secrets_set", Description: "Keep a connection's secret field values in the Keychain, merged with what is already there."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionSecretsArgs) (*mcp.CallToolResult, empty, error) {
			if _, ok := wakilcore.ConnectionFor(a.ID, a.Name); !ok {
				return toolErr(wakilcore.UserError("no connection " + a.Name + " in " + a.ID)), empty{}, nil
			}
			if err := wakilcore.SetConnectionSecrets(a.ID, a.Name, a.Values); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_allow_set", Description: "Switch one of a connection's tools on or off at the gate. A destructive tool stays off and is refused."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionAllowArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetConnectionAllow(a.ID, a.Name, a.Tool, a.Allow); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_signin_start", Description: "Begin a connection's browser sign-in and answer the page to open; this opens nothing itself. A second start replaces the first. Follow it with connection_signin_wait."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionNameArgs) (*mcp.CallToolResult, connectionSignInStartOut, error) {
			u, err := wakilcore.StartConnectionSignIn(ctx, a.ID, a.Name)
			if err != nil {
				return toolErr(err), connectionSignInStartOut{}, nil
			}
			return nil, connectionSignInStartOut{URL: u}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_signin_wait", Description: "Wait for the browser sign-in connection_signin_start began, keep its tokens in the Keychain and answer the account. Cancelling the call ends the sign-in and keeps nothing."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionNameArgs) (*mcp.CallToolResult, connectionSignInWaitOut, error) {
			account, err := wakilcore.WaitConnectionSignIn(ctx, a.ID, a.Name)
			if err != nil {
				return toolErr(err), connectionSignInWaitOut{}, nil
			}
			return nil, connectionSignInWaitOut{Account: account}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "connection_signout", Description: "Forget a connection's browser sign-in tokens, keeping your own app's client id and secret."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a connectionNameArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SignOutConnection(a.ID, a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "jira_token_set", Description: "Keep an organisation's Jira sign-in (Atlassian email and API token) in the Keychain."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a jiraTokenArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetJiraToken(a.ID, a.Email, a.Token); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_key_passphrase_set", Description: "Keep the passphrase of a key an organisation picked from ~/.ssh in the Keychain."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitSecretArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.SetGitKeyPassphrase(a.ID, a.Host, a.Passphrase); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_account_test", Description: "Ask a host who an organisation's account there is: ssh -T with its key, or the provider's user API with its token. Answers the name, or the host's refusal."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitAccountArgs) (*mcp.CallToolResult, gitTestOut, error) {
			user, err := wakilcore.TestGitAccount(ctx, a.ID, a.Host)
			if err != nil {
				return toolErr(err), gitTestOut{}, nil
			}
			return nil, gitTestOut{User: user}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_device_start", Description: "Begin a provider's Sign in (device flow): answers the code the operator types and the page to type it on."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitOrgArgs) (*mcp.CallToolResult, wakilcore.DeviceCode, error) {
			code, err := wakilcore.DeviceStart(ctx, a.Provider)
			if err != nil {
				return toolErr(err), wakilcore.DeviceCode{}, nil
			}
			return nil, code, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_device_poll", Description: "Ask once whether the operator approved a Sign in; on approval the token goes to the Keychain and the account is recorded."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitDevicePollArgs) (*mcp.CallToolResult, gitDevicePollOut, error) {
			token, pending, err := wakilcore.DevicePoll(ctx, a.Provider, a.DeviceCode)
			if err != nil {
				return toolErr(err), gitDevicePollOut{}, nil
			}
			if pending {
				return nil, gitDevicePollOut{Pending: true}, nil
			}
			finish := wakilcore.FinishSignIn
			if a.APIAccess {
				finish = func(org, _, host, token string) error { return wakilcore.FinishAPIAccessSignIn(org, host, token) }
			}
			if err := finish(a.ID, a.Provider, a.Host, token); err != nil {
				return toolErr(err), gitDevicePollOut{}, nil
			}
			return nil, gitDevicePollOut{Done: true}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_gh_logins", Description: "The logins the GitHub CLI holds (gh auth status); none without gh."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitOrgArgs) (*mcp.CallToolResult, gitGhLoginsOut, error) {
			return nil, gitGhLoginsOut{Logins: wakilcore.GhLogins()}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_gh_import", Description: "Copy one gh login's token into the organisation's Keychain once and record it as the host's account."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitAccountArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.ImportGhLogin(a.ID, a.Host, a.User); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_project_agent_instructions", Description: "Change one project's agent instructions (general, commits, pull requests) and its Agents woken by messages, written to its project.json, read-modify-write; omit a field to leave it unchanged, \"\" to clear it."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setProjectAgentArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.UpdateProjectAgentInstructions(a.ProjectPath, wakilcore.ProjectAgentPatch{
				General: a.General, Commits: a.Commits, PullRequests: a.PullRequests, Branches: a.Branches, MessageWakes: a.MessageWakes,
			}); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_account_remove", Description: "Forget an organisation's git account for one host: its Keychain secrets go, and a key Wakil generated goes to the Trash."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a gitAccountArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RemoveGitAccount(a.ID, a.Host); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "create_project", Description: "Create a project in a folder and register it in the active organisation. Writes the folder's .wakil/project.json (name, org, one root) or adopts the one already there, under that file's own name; returns the name it was registered under. Refuses a folder already registered, a name already taken, and a project filed under another organisation; nothing is written on a refusal."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a createProjectArgs) (*mcp.CallToolResult, createProjectOut, error) {
			// The key it was filed under: the trimmed name, or an adopted file's own.
			key, entry, err := wakilcore.CreateProject(a.Folder, a.Name)
			if err != nil {
				return toolErr(err), createProjectOut{}, nil
			}
			return nil, createProjectOut{Name: key, Path: entry.Path}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "rename_project", Description: "Rename a project: rewrites the name in its project.json and the registry key. The active project follows the new name. Refuses a name already taken."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a renameProjectArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RenameProject(a.Name, a.NewName); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// **Removing a project KEEPS its project.json** — only the registry row goes.
	mcp.AddTool(s, &mcp.Tool{Name: "remove_project", Description: "Remove a project from the registry. Its project.json stays on disk, untouched, so the folder can be registered again later; nothing in the project's folder is deleted."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a removeProjectArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RemoveProject(a.Name); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "create_environment", Description: "Add an empty environment to a project, named with the first free name of new-environment, new-environment-2, and so on. Returns the name it chose. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a createEnvironmentArgs) (*mcp.CallToolResult, createEnvironmentOut, error) {
			name, err := wakilcore.CreateEnvironment(a.ProjectPath)
			if err != nil {
				return toolErr(err), createEnvironmentOut{}, nil
			}
			return nil, createEnvironmentOut{Name: name}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "rename_environment", Description: "Rename an environment; its databases and API entries move with it, and the active environment follows. Refuses a name already taken and a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a renameEnvironmentArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RenameEnvironment(a.ProjectPath, a.Name, a.NewName); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_environment_production", Description: "Declare whether an environment is production (yes or no), or clear the declaration so its name decides (name). What counts as production sets the agent's price. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a setEnvironmentProductionArgs) (*mcp.CallToolResult, empty, error) {
			var production *bool
			switch a.Production {
			case "yes", "no":
				v := a.Production == "yes"
				production = &v
			case "name":
			default:
				return toolErr(wakilcore.UserError("production must be yes, no or name")), empty{}, nil
			}
			if err := wakilcore.SetEnvironmentProduction(a.ProjectPath, a.Name, production); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	// **Removing an environment Trashes a copy of project.json FIRST**; if
	// the Trash fails nothing is removed.
	mcp.AddTool(s, &mcp.Tool{Name: "remove_environment", Description: "Remove an environment from a project. A copy of project.json, as it was before, is put in the Trash first (returned as trashed); if the Trash refuses, nothing is removed. The environment's databases' Keychain entries are KEPT. Refuses a project filed under another organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a removeEnvironmentArgs) (*mcp.CallToolResult, removeEnvironmentOut, error) {
			trashed, err := wakilcore.RemoveEnvironment(a.ProjectPath, a.Name, time.Now())
			if err != nil {
				return toolErr(err), removeEnvironmentOut{}, nil
			}
			return nil, removeEnvironmentOut{Trashed: trashed}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "adopt_provider", Description: "Bind an account that already exists on this machine into another organisation, as a shared registration. Name fromOrg and fromId and the source binding's credential is COPIED into the adopting organisation's own Keychain item, so the binding can start a session immediately and no browser opens; omit them to copy nothing. The resolved agent-binary path is recorded from the source. The config dir keeps its existing headless home — a plain claude session started there still runs as the homing organisation — unless nothing homes it, in which case this binding becomes the home. A source that holds no credential, or a Keychain that will not answer, does not undo the binding: the row is created and reports its credential missing, which is repairable from that row."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a adoptProviderArgs) (*mcp.CallToolResult, wakilcore.AdoptOutcome, error) {
			outcome, err := wakilcore.AdoptProvider(wakilcore.AdoptRequest{
				Org: a.Org, ID: a.ID, Kind: a.Kind, Label: a.Label,
				ConfigDir: a.ConfigDir, FromOrg: a.FromOrg, FromID: a.FromID,
			})
			if err != nil {
				return toolErr(err), outcome, nil
			}
			return nil, outcome, nil
		})

	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}

// configTreeFor reads the named organisation's tree, or the active one's when id is empty.
func configTreeFor(id string) (wakilcore.ConfigTree, error) {
	if id == "" {
		return wakilcore.LoadConfigTree()
	}
	return wakilcore.LoadConfigTreeFor(id)
}
