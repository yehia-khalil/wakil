package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Project struct {
	Name         string                 `json:"name"`
	Org          string                 `json:"org"`
	Roots        []Root                 `json:"roots"`
	Scopes       Scopes                 `json:"scopes"`
	Environments map[string]Environment `json:"environments"`
	// Editor is the project's editor settings (3b-v, Decision 38): the values that belong to the
	// code, committed with it. Absent means every default.
	Editor *EditorProjectSettings `json:"editor,omitempty"`
	// Agent is the project's agent instructions (3a-iii-b), after the organisation's.
	Agent *ProjectAgentInstructions `json:"agent,omitempty"`
}

type Root struct {
	Path string `json:"path"`
	Role string `json:"role,omitempty"`
}

type Scopes struct {
	PM *PMScope `json:"pm,omitempty"`
}

type PMScope struct {
	Provider   string `json:"provider"`
	ProjectKey string `json:"projectKey"`
}

type Environment struct {
	Databases []Database `json:"databases"`
	// API is the environment's named API entries (#183).
	//
	// **`"api"` KEPT ITS KEY and became an array**, rather than being
	// renamed to `"apis"` beside a retired singular. Changing the type in
	// place fails loudly at `LoadProject` — an object where an array is
	// expected is a decode error naming the field. Renaming the key would
	// make every existing `"api": {…}` an unknown field that
	// `json.Unmarshal` silently ignores, so an environment that reaches
	// nothing would be reported as nothing wrong. There is no config
	// versioning in this repo and this does not add any; the whole
	// population is two files plus one acceptance doc.
	API []ApiConfig `json:"api,omitempty"`
	// Production declares whether this environment IS production, rather
	// than being named it (Decision 26, #182).
	//
	// **A pointer because absent is not false.** Wakil never materialises
	// the default: "absent means not production" would stop every shipped
	// project's production environment being production on one release,
	// silently, with no configuration edit anywhere to show for it. Absent
	// means *read the name*, which is exactly what every project on disk
	// relies on today.
	//
	// **Authoritative in both directions.** `production: true` makes an
	// environment production whatever it is spelled, which is the half
	// that matters: an environment named `prod` lost both the red room and
	// the typed confirmation, silently, because the only rule was an exact
	// match on the word. `production: false` on one NAMED `production` is
	// honoured too — a deliberate disarm replacing an accidental one. Both
	// surprising shapes are surfaced once with the environment listing;
	// see EnvironmentNamingNotice.
	Production *bool `json:"production,omitempty"`
}

type Database struct {
	Name   string `json:"name"`
	Driver string `json:"driver"`
	Ref    string `json:"ref"`
	// WriteRef names a SECOND Keychain entry, holding a credential the
	// database server has granted write permission to. Empty — which is
	// every database configured before Phase 2b-iii — means this database
	// cannot be mutated by anything: not by the agent, not by the
	// operator, not by --dispatch.
	//
	// That is Invariant 6 ("read-only until a write earns its way in")
	// applied per resource rather than per phase. A second credential
	// rather than a boolean because write authority should be proven TO
	// THE SERVER, by presenting something the server itself granted,
	// rather than asserted by Wakil to itself — the same reasoning
	// keychainService uses to put the org in the service name, and that
	// hardenMySQLConfig uses to discard rather than filter.
	//
	// It is also the only shape Mongo could ever use: driver_mongo.go
	// records that no client setting makes a *mongo.Client refuse a
	// write, so the read/write distinction there IS the credential's
	// grants and cannot be anything else.
	WriteRef string `json:"writeRef,omitempty"`
	// Connection holds the non-secret parts of a database saved as parts
	// (2e-iv). When set, the Keychain items at Ref and WriteRef hold only
	// PASSWORDS and the connection string is built at connect time. Nil is
	// a legacy record: its Keychain item is the whole connection string,
	// read exactly as before.
	Connection *DatabaseConnection `json:"connection,omitempty"`
}

// DatabaseInfo is what an agent is told about a database, and it is a
// separate type from Database on purpose.
//
// Database is the on-disk shape, and it had been serving as the wire shape
// too. That published readOnly — a field that granted and protected
// nothing — while hiding writeRef behind omitempty, so the ONE field that
// decides whether a mutation can run was invisible in exactly the case
// where it decides "no". During the permission-prompt bridge acceptance
// run on 2026-09-10 that derailed three separate live agent turns: each
// read readOnly:true, concluded a write was impossible, and declined
// without ever calling db_run_mutation, so the write gate under test was
// never reached. One turn's reasoning said so outright — "core is marked
// read-only there" — a confident statement about a field that governed
// nothing. Recorded as issue #14 and in permission-prompt-acceptance.md,
// finding 2.
//
// So: publish what the agent can act on, and nothing else. Writable is
// derived from WriteRef rather than stored, because a stored copy is a
// second source of truth for a safety property and would drift. Neither
// Ref nor WriteRef appears here — they are Keychain ENTRY NAMES, of no use
// to an agent and no business of one.
type DatabaseInfo struct {
	Name   string `json:"name"`
	Driver string `json:"driver"`
	// Writable carries no omitempty, deliberately. An omitted false would
	// leave an agent unable to distinguish "not writable" from "this
	// server does not report writability", and the cautious reading of the
	// second is not the same action as the first. Every entry states it.
	Writable bool `json:"writable"`
}

// NewDatabaseInfo projects the on-disk record onto the wire shape.
func NewDatabaseInfo(d Database) DatabaseInfo {
	return DatabaseInfo{Name: d.Name, Driver: d.Driver, Writable: d.WriteRef != ""}
}

// DatabaseList wraps a []DatabaseInfo so wakil-db's list_databases tool can
// return one.
//
// The wrapper is not decoration. MCP requires a tool result's
// structuredContent to be a JSON OBJECT, and the MCP SDK derives a tool's
// advertised outputSchema from the handler's typed Out — so declaring Out
// as []Database advertised a top-level {"items":…,"type":["null","array"]}
// and put a bare array on the wire. A validating client rejects that, and
// list_databases duly failed outright in the Phase 1 acceptance run while
// every object-typed tool in the same server worked. Wrapping keeps the
// full, precise per-database schema AND produces an object; see
// internal/mcpx's ToolErr doc comment for the rule and the measurement.
//
// Unlike IssuePage and SessionList, this type carries no completeness or
// count signal, and deliberately so: env.Databases is read whole from the
// active environment in project.json, so the list is complete by
// construction — there is no paging, no cap, and no step that can silently
// drop an entry. A Truncated field here could only ever be false, which is
// worse than absent: it would imply a check nothing performs.
type DatabaseList struct {
	// Databases is never nil when built through NewDatabaseList, so an
	// environment with no databases marshals to [] rather than null.
	Databases []DatabaseInfo `json:"databases"`
}

// NewDatabaseList projects on-disk records onto the wire shape, with a
// guaranteed non-nil Databases slice. Pass nil (as the error paths do) to
// get {"databases":[]}.
//
// It takes []Database rather than []DatabaseInfo so that this is the only
// place the projection happens: a caller handed the wire type directly
// could assemble a DatabaseInfo whose Writable disagreed with the WriteRef
// it was derived from, which is the exact class of lie issue #14 was.
func NewDatabaseList(databases []Database) DatabaseList {
	out := make([]DatabaseInfo, 0, len(databases))
	for _, d := range databases {
		out = append(out, NewDatabaseInfo(d))
	}
	return DatabaseList{Databases: out}
}

// ApiConfig is one named API entry of an environment.
//
// An environment named ONE api until #183, so a project whose backends are
// separate subdomains — `api`, `auth`, `billing` — could reach exactly one
// of them. Each entry carries its OWN credential, which is the point
// rather than a convenience: one backend's token never reaches another
// backend's host.
type ApiConfig struct {
	// Name is required, exactly as Database has one, and is what a
	// request records — never the origin. That is what lets the same
	// request run against staging and then against production.
	Name    string `json:"name"`
	BaseURL string `json:"baseUrl"`
	AuthRef string `json:"authRef,omitempty"`
	// AuthHeader names the header the credential is placed in, defaulting
	// to Authorization. An entry whose backend authenticates through
	// something else — `X-API-Key` — is configurable so that the Keychain,
	// and not a tool call, stays where the secret lives. Read through
	// Header() rather than directly, so the default lives in one place.
	AuthHeader string `json:"authHeader,omitempty"`
}

// Header is the header name this entry's credential is sent in, trimmed,
// with the default applied. It is the ONLY place that default lives —
// doRequest resolves through ResolveAuthHeader rather than repeating it,
// because two copies of a default are two things that can disagree about
// where a credential goes.
func (a ApiConfig) Header() string { return ResolveAuthHeader(a.AuthHeader) }

// ResolveAuthHeader trims name and supplies the Authorization default.
func ResolveAuthHeader(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "Authorization"
	}
	return trimmed
}

// ValidateAuthHeader refuses an authHeader that would put the credential
// somewhere it cannot work, or somewhere it must not go.
//
// **The silent case is why this exists.** `authHeader: "Host"` makes
// `req.Header.Set` a no-op — net/http takes the wire Host from
// `Request.Host` alone — so the request leaves UNAUTHENTICATED with no
// error at all, and the operator learns about it as a 401 from a backend
// they configured a credential for. That is controller ruling 3's silent
// downgrade reached from the other side, and it is the one failure here
// that reports nothing.
//
// `Cookie` and `Proxy-*` are refused for the deny list's own reason: a
// credential in a `Proxy-*` header is the request steered through a proxy
// of the configuration's choosing, which is exactly what that list exists
// to stop a caller doing. A name that is not a valid HTTP token is refused
// here rather than after a Keychain read, so the operator's login keychain
// is not consulted to answer a question the configuration already answers.
func ValidateAuthHeader(name string) error {
	resolved := ResolveAuthHeader(name)
	lower := strings.ToLower(resolved)
	switch {
	case lower == "host":
		return UserError("authHeader Host cannot carry a credential: net/http takes the " +
			"wire Host from the request URL, so the header would be dropped and the " +
			"request would leave unauthenticated")
	case lower == "cookie":
		return UserError("authHeader Cookie is not allowed; use Authorization or a custom header")
	case strings.HasPrefix(lower, "proxy-"):
		return UserError("authHeader " + resolved + " is not allowed: a Proxy-* header " +
			"steers the request through a proxy rather than authenticating it")
	}
	for _, r := range resolved {
		if r <= ' ' || r >= 0x7f || strings.ContainsRune("()<>@,;:\\\"/[]?={}\t", r) {
			return UserError("authHeader " + strconv.Quote(resolved) +
				" is not a valid HTTP header name")
		}
	}
	return nil
}

// ApiInfo is what an agent is told about one API entry, and it is a
// separate type from ApiConfig for DatabaseInfo's reason: the on-disk shape
// names a Keychain entry, and a Keychain entry name is of no use to an
// agent and no business of one. Neither AuthRef nor AuthHeader appears
// here — which header carries the credential is not an agent's concern
// either, and publishing it would tell a caller exactly which header to try
// to override.
type ApiInfo struct {
	Name    string `json:"name"`
	BaseURL string `json:"baseUrl"`
	// Authenticated carries Writable's mitigation sentence in shape: true
	// means only that a credential is CONFIGURED, never that it is valid
	// or sufficient. Derived from AuthRef rather than stored, because a
	// stored copy is a second source of truth for a safety property and
	// would drift — issue #14's exact shape.
	//
	// No omitempty, for Writable's reason: an omitted false leaves an
	// agent unable to tell "not credentialed" from "this build does not
	// report it".
	Authenticated bool `json:"authenticated"`
}

// ApiList wraps []ApiInfo so wakil-http's list_apis can return an object.
// MCP requires structuredContent to be a JSON object and the SDK derives
// the advertised outputSchema from the handler's Out, so a slice-typed Out
// ships a bare array and a validating client rejects the whole call — see
// internal/mcpx's ToolErr comment for the measurement.
//
// Like DatabaseList this carries no completeness signal, and deliberately:
// the entries are read whole from the active environment, so the list is
// complete by construction. A Truncated field here could only ever be
// false, which is worse than absent.
type ApiList struct {
	// Apis is never nil when built through NewApiList, so an environment
	// with no entries marshals to [] rather than null.
	Apis []ApiInfo `json:"apis"`
}

// NewApiList projects on-disk records onto the wire shape. It takes
// []ApiConfig rather than []ApiInfo so that this is the only place the
// projection happens: a caller handed the wire type could assemble an
// ApiInfo whose Authenticated disagreed with the ref it was derived from.
func NewApiList(entries []ApiConfig) ApiList {
	out := make([]ApiInfo, 0, len(entries))
	for _, e := range entries {
		out = append(out, ApiInfo{Name: e.Name, BaseURL: e.BaseURL, Authenticated: e.AuthRef != ""})
	}
	return ApiList{Apis: out}
}

func LoadProject(path string) (*Project, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read project.json: %w", err)
	}
	var p Project
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, fmt.Errorf("parse project.json: %w", err)
	}
	if p.Name == "" || p.Org == "" {
		return nil, fmt.Errorf("project.json missing name or org")
	}
	return &p, nil
}

// EnvironmentInfo is what an agent is told about one environment, and it is
// a separate type from Environment for `DatabaseInfo`'s reason: the on-disk
// shape names Keychain refs and connection details that are no business of
// an agent, and the wire shape publishes only what one can act on.
//
// **`readOnly` used to be the whole answer.** `list_environments` returned a
// flat `map[string]bool`, which could say one thing and had to say it about
// every environment — so Decision 26's `production` flag had nowhere to go,
// and the app went on deciding production by comparing the name. Two
// booleans in a named object is the shape that stops the app re-deriving a
// safety property the configuration already states.
type EnvironmentInfo struct {
	// ReadOnly is true when nothing in this environment is configured for
	// writing — and true *vacuously* for an environment declaring nothing
	// at all. It is never evidence that an environment IS configured.
	ReadOnly bool `json:"readOnly"`
	// Production is the flag's EFFECT, never the flag: declared when the
	// environment declares, and the name's default when it does not. An
	// agent reading this must not re-derive it by comparing the name,
	// which is the drift `EnvironmentIsProduction` exists to prevent.
	//
	// No omitempty, for `DatabaseInfo.Writable`'s reason: an omitted false
	// leaves a reader unable to tell "not production" from "this build
	// does not report it", and the cautious reading of the second is not
	// the same action as the first.
	Production bool `json:"production"`
	// Notice is a sentence about THIS environment, when a reader of the
	// configuration would misread it — a `prod`/`prd`/`live`/`preprod`
	// carrying no production flag, or a `production` declaring false.
	// Empty when there is nothing surprising to say.
	//
	// **It sits on the environment rather than in a list beside them.**
	// Every notice is about exactly one environment, and a flat list could
	// not say which — so a surface drawing the listing had to heap them
	// above the rows, detached from the thing they name and truncated,
	// because a row's width is not a paragraph's. Attached, each is drawn
	// where its environment is, and the list that could not carry the
	// association is gone rather than kept beside it as a second answer.
	//
	// **Still once, and still never per call.** A warning on every action
	// that touches the environment is a warning nobody reads; this one is
	// met exactly when somebody is looking at the environments.
	Notice string `json:"notice,omitempty"`
}

// EnvironmentList is what `list_environments` answers.
//
// **A wrapper, not decoration.** The tool used to declare `map[string]bool`
// as its Out, which is a JSON object and so was legal — but a bare boolean
// per environment could say only one thing, and this listing now carries
// three. See internal/mcpx's ToolErr comment for why the shape of an Out is
// load-bearing rather than cosmetic.
type EnvironmentList struct {
	// Environments is never nil when built through NewEnvironmentList, so a
	// project with no environments marshals to {} rather than null.
	Environments map[string]EnvironmentInfo `json:"environments"`
}

// NewEnvironmentList projects on-disk records onto the wire shape, with
// guaranteed non-nil members.
//
// It takes the map of `Environment` rather than of `EnvironmentInfo` so that
// this is the only place the projection happens: a caller handed the wire
// type could assemble an `EnvironmentInfo` whose `Production` disagreed with
// the flag it was derived from, which is the class of lie issue #14 was.
//
// **Every field of `EnvironmentInfo` is computed here, in this package.**
// `ReadOnly` used to arrive as an injected predicate with exactly one
// implementation, living in `cmd/wakil-ctx` while its sibling
// `EnvironmentIsProduction` lived here — so one wire type was assembled from
// two packages, and the error path passed a callback that was never called.
// Both rules are `wakilcore`'s: they are read off `Environment`, and nothing
// about either is specific to the tool that serves them.
func NewEnvironmentList(environments map[string]Environment) EnvironmentList {
	out := EnvironmentList{Environments: map[string]EnvironmentInfo{}}
	names := make([]string, 0, len(environments))
	for name := range environments {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		env := environments[name]
		out.Environments[name] = EnvironmentInfo{
			ReadOnly:   EnvironmentIsReadOnly(env),
			Production: EnvironmentIsProduction(name, env),
			Notice:     EnvironmentNamingNotice(name, env),
		}
	}
	return out
}
