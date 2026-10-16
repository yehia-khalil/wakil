package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Provider is one agent account attached to an org, stored at
// ~/.wakil/orgs/<org>/providers/<id>.json.
//
// Providers and orgs are independent axes: an org may hold several
// providers (two Claude subscriptions for rate-limit headroom, plus a
// local model), and the same account may serve several orgs. Nothing
// about an org's credentials depends on which provider is running.
type Provider struct {
	// ID is the file's basename, not a field in the file, so the two
	// cannot disagree.
	ID string `json:"-"`

	Kind      string `json:"kind"`
	Label     string `json:"label,omitempty"`
	ConfigDir string `json:"configDir,omitempty"`

	// ClaudePath is the agent binary this provider launches, formerly the
	// WAKIL_CLAUDE_PATH environment variable. It is a record field and not
	// a Keychain item because a path is not a credential: putting it in the
	// Keychain would mean a Keychain read to answer "which binary", which is
	// both slower and misleading about what is sensitive. It is genuinely
	// per-provider — a codex or local provider is a different binary
	// entirely, not a different account for the same one.
	ClaudePath string `json:"claudePath,omitempty"`

	// Shared records that this binding did NOT claim the config dir's
	// headless home — another org's registration did. It exists so
	// ConfigDirHome can name the org whose WAKIL_ORG is pinned inside the
	// directory, which is the only org a plain `claude` session started
	// there will ever run as.
	//
	// It is a property of the RECORD's relationship to the directory, not
	// of the account: the account is shared either way. The name was kept
	// despite that ambiguity because no better one was found; see the
	// design document's §8.
	Shared bool `json:"shared,omitempty"`
}

// Provider kinds. Only claude-code has a session adapter (sessions.go's
// providerSessionsRoot) and automated MCP registration
// (scripts/register-provider.sh). The other two are recorded so an org
// can describe what it actually has: 14 of the 16 Wakil tools are plain
// stdio MCP and work under any MCP-capable
// client, so a codex or local provider is genuinely useful — it is only
// session discovery that goes dark. Recording a kind we do not automate
// is honest; claiming to automate a client that has never been tested
// would not be.
const (
	ProviderKindClaudeCode = "claude-code"
	ProviderKindCodex      = "codex"
	ProviderKindLocal      = "local"
)

// ProviderTokenRef is the secrets ref a provider's OAuth token lives
// under: "provider:<id>", resolving to the Keychain service name
// "wakil:<org>:provider:<id>" through keychainService.
//
// DERIVED, NOT STORED. validateProviderToken already constrains a
// provider id to exactly the character set a Keychain ref needs — it
// reuses orgFileTokenPattern for that reason — so nothing has to be
// validated here that AddProvider has not already refused. A stored
// tokenRef field would add a second string that can disagree with the
// filename, which is the failure Provider.ID's own `json:"-"` was
// written to prevent.
//
// THE CONSEQUENCE, AND IT IS THE ONE THING TO KNOW BEFORE SHARING AN
// ACCOUNT: the ref carries no org, so the org comes from the CALLER's
// environment, and the same account reached from two orgs needs the same
// token stored twice, once per org.
//
// `wakil provider credentials <id>` resolves this ref under CurrentOrg()
// (cmd/wakil/providercredentials.go), and the window bakes its own org
// into the lookup at construction (WakilCLICredentialsLookup, see
// WindowSession.swift). So a binding `initech-main` registered in org
// `personal` — the same Claude account `initech` homes — reads
// `wakil:personal:provider:initech-main`, an item that does NOT exist merely
// because `wakil:initech:provider:main` does. Registering the share is half
// the job; `wakil secrets set provider:initech-main --org personal` with the
// same token pasted is the other half, and without it the window refuses
// to start a session under the shared provider. `operator-todo.md`'s
// migration section carries the exact commands.
//
// An earlier version of this comment asserted that "AddProvider already
// refuses two providers sharing a config dir". It no longer does — that
// refusal becoming conditional on --share is precisely what this
// sub-phase shipped — and the sentence is replaced rather than amended
// because it was the one place a reader would have been warned.
func ProviderTokenRef(id string) string { return "provider:" + id }

// validateProviderToken reports whether id can be used as a provider's
// filename. It reuses orgFileTokenPattern rather than declaring a second
// pattern — a provider id and an org id have the exact same filename and
// Keychain-token constraints — but produces a provider-worded message so
// a rejected provider id does not read as a rejected org id.
func validateProviderToken(id string) error {
	if orgFileTokenPattern.MatchString(id) {
		return nil
	}
	return UserError("unusable provider id " + strconv.Quote(id) +
		" — a provider id must start with a letter or digit and contain only letters, digits, dot, dash or underscore")
}

func providersDirFor(org string) (string, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "providers"), nil
}

// AddProvider registers a new provider record under org. It refuses an
// id that is not a usable filename, a kind outside the three declared
// above, a claude-code provider whose configDir does not exist, a
// non-claude-code provider that supplies a configDir at all, a
// duplicate id, and — the whole of the config-dir block below — every
// registration the sharing rules forbid.
//
// The sharing rules, since a reader arriving here for "what does
// --share do" should not have to reconstruct them from the switch:
// a config dir has at most one HEADLESS HOME, the org whose WAKIL_ORG
// scripts/register-provider.sh pinned inside it, and any number of
// additional Wakil-only bindings from OTHER orgs, each of which must
// say --share. So p.Shared is refused within one org whatever else is
// true (one org may name one account once), required when another org
// already homes the dir, refused when nobody does (there is nothing to
// share yet), and refused outright on a kind that has no config dir to
// share in the first place.
func AddProvider(org string, p Provider) error {
	if err := validateProviderToken(p.ID); err != nil {
		return err
	}
	switch p.Kind {
	case ProviderKindClaudeCode:
		if p.ConfigDir == "" {
			return UserError("a claude-code provider needs --config-dir (the CLAUDE_CONFIG_DIR that account uses)")
		}
		abs, err := filepath.Abs(p.ConfigDir)
		if err != nil {
			return err
		}
		// Resolve symlinks: the servers really do read the target, and the
		// recorded value is what session discovery will open later.
		resolved, err := filepath.EvalSymlinks(abs)
		if err != nil {
			return UserError("configDir does not exist: " + abs)
		}
		fi, err := os.Stat(resolved)
		if err != nil || !fi.IsDir() {
			return UserError("configDir is not a directory: " + resolved)
		}
		p.ConfigDir = resolved
	case ProviderKindCodex, ProviderKindLocal:
		if p.ConfigDir != "" {
			return UserError("configDir applies only to --kind claude-code")
		}
		// --share is refused here rather than ignored. What is shared is a
		// config dir's headless home, and these kinds have no config dir at
		// all, so there is nothing the flag could name. Accepting it stored
		// `"shared": true` on a record with an empty ConfigDir, and every
		// downstream reader of that combination then answered a question
		// about a directory that does not exist — `wakil provider add`'s own
		// confirmation printed "still pins WAKIL_ORG inside " with the path
		// missing, naming whichever unrelated record also had an empty
		// ConfigDir. A flag that cannot mean anything must not be accepted;
		// the alternative, silently dropping it, leaves the operator
		// believing they registered a share.
		if p.Shared {
			return UserError("--share applies only to --kind " + ProviderKindClaudeCode +
				" — sharing is about a config dir's headless home (the org whose WAKIL_ORG is pinned inside it)," +
				" and a " + p.Kind + " provider has no config dir." +
				" Re-run without --share")
		}
	default:
		return UserError("unknown provider kind " + strconv.Quote(p.Kind) +
			" — one of " + ProviderKindClaudeCode + ", " + ProviderKindCodex + ", " + ProviderKindLocal)
	}

	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, p.ID+".json")
	if _, err := os.Stat(path); err == nil {
		return UserError("provider " + strconv.Quote(p.ID) + " already exists in org " + strconv.Quote(org))
	}
	// Checked after the duplicate-id stat so that re-adding an existing id
	// against its own configDir reports the duplicate rather than a
	// collision with itself, and after the symlink resolution above so that
	// two names for one directory are recognised as one directory.
	if p.ConfigDir != "" {
		// TWO questions, asked separately, because one lookup cannot answer
		// both and conflating them is exactly how this went wrong.
		//
		// The first cut of this block asked findConfigDirOwner(dir, false)
		// once — "does ANY record name this dir" — and branched on whether
		// the single answer's org equalled this one. That answer is the
		// FIRST match in ListOrgs() sort order, which once sharing exists
		// can be a SHARED record in a third org. With `zulu` homing a dir
		// and `alpha` sharing it, an add into `zulu` got back
		// ("alpha", the sharer): the same-org branch did not fire because
		// the orgs differed, the cross-org branch was skipped because
		// --share was set, and the add fell through and wrote `zulu` a
		// SECOND record for its own dir — the one row the design's §4.2
		// matrix says is refused always.
		//
		// So: scan THIS org for a record naming the dir, and ask
		// ConfigDirHome who homes it. Neither question can answer the
		// other, and neither depends on org sort order.
		sameOrgID, err := findConfigDirInOrg(org, p.ConfigDir)
		if err != nil {
			return err
		}
		homeOrg, homeID, err := ConfigDirHome(p.ConfigDir)
		if err != nil {
			return err
		}
		switch {
		case sameOrgID != "":
			// Refused whatever the flags say, and --share does not rescue
			// it — shared or not, a second record in this org names one
			// account twice. WAKIL_ORG would survive a second registration
			// but WAKIL_PROVIDER would not, so sessions land under whichever
			// provider registered last; and a second id naming one account
			// buys no second account and no second quota, which is the only
			// reason sharing exists at all.
			return UserError("configDir " + strconv.Quote(p.ConfigDir) +
				" is already registered to provider " + strconv.Quote(sameOrgID) +
				" in this same org — one org may name one account once." +
				" Sharing is between different orgs; within one it would only" +
				" duplicate the record, and sessions would land under whichever" +
				" WAKIL_PROVIDER was registered last. --share does not change this." +
				" Use a different config dir, or release this one with: wakil provider rm " +
				sameOrgID + " --org " + org)
		case homeOrg != "" && !p.Shared:
			// Named from ConfigDirHome, so this names the org and provider
			// that actually PINNED the directory. Naming the first match
			// instead put another SHARER's org in this sentence, which made
			// every clause of it false: that org pins nothing, a plain
			// `claude` session there does not run as it, and the suggested
			// `provider rm` would have deleted a legitimate share while
			// releasing nothing.
			return UserError("configDir " + strconv.Quote(p.ConfigDir) +
				" is already registered to provider " + strconv.Quote(homeID) +
				" in org " + strconv.Quote(homeOrg) +
				" — that org pins WAKIL_ORG inside the directory, so a plain" +
				" `claude` session started there runs as " + homeOrg + "." +
				" To use this same account from org " + strconv.Quote(org) +
				" inside Wakil, re-run with --share: Wakil passes each session its" +
				" own org and never reads the pin, so the two do not collide." +
				" Plain Claude Code in that directory stays with " + homeOrg + "." +
				" Or use a different config dir, or release this one with: wakil provider rm " +
				homeID + " --org " + homeOrg)
		case homeOrg != "":
			// Another org homes it and --share was given: the legitimate
			// share. This record is Wakil-only and the home does not move.
		case p.Shared:
			// **Nobody homes the dir, so this record BECOMES the home**
			// (2e, #201) — where it used to be refused outright.
			//
			// This is one of the two changes in the ADD path that let
			// #206 drop `RemoveProvider`'s orphan refusal, which rests on
			// a claim that was measured false. The other is recording the
			// resolved `claudePath` (see AdoptProvider). Two changes here,
			// none in the remove path.
			//
			// The case this rescues is the one the old branch named and
			// then refused: a home record deleted by hand out from under
			// its sharers, leaving orphans. Under the old rule those
			// orphans could not be re-homed by adding a binding — the
			// operator had to know to drop `--share` — and the settings
			// pane's Adopt control has no `--share` to drop, because
			// every adoption it performs sets it.
			//
			// **The cost, named rather than discovered later.** A record
			// that becomes the home says it pinned `WAKIL_ORG` inside the
			// directory, and nothing here writes that pin —
			// `scripts/register-provider.sh` does. So a directory re-homed
			// this way has a record and a pin that disagree until that
			// script is run for it. That mismatch is survivable for
			// Wakil's own sessions, which pass each session its own org
			// and never read the pin; it is visible only to a plain
			// `claude` session started in that directory, which keeps
			// running as whatever the pin still says.
			//
			// Shared is cleared rather than left set, because it would
			// otherwise be a record claiming to share a directory nothing
			// homes — which is precisely the shape `ResolveProviderClaudePath`
			// has no answer for.
			p.Shared = false
		default:
			// Nobody homes it and no --share: this record becomes the home.
		}
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

// findConfigDirOwner reports which provider, in which org, already
// records dir as its configDir. It returns "", "", nil when none does.
//
// dir must already be absolute and symlink-resolved: every stored
// ConfigDir went through AddProvider's EvalSymlinks, so comparing a raw
// path here would miss a symlink to a claimed directory — which is the
// same directory, and would collide identically once a client wrote into
// it.
//
// The scan spans every org, not just the one being added to, because the
// thing being protected is a directory on disk and directories know
// nothing about orgs. It reads the whole provider tree, which is a few
// dozen small files at the very most and only on `provider add`.
//
// A provider record that fails to parse is skipped by listProvidersFor
// and therefore cannot be reported as an owner. That is deliberate: such
// a record is already invisible to every other caller, and failing the
// add instead would let one corrupt file block all registration. The
// cost is that a collision hidden behind a corrupt record goes
// undetected — strictly no worse than before this guard existed.
//
// homeOnly selects between the two questions this function answers. True
// is "which record PINNED it", which is what ConfigDirHome exposes and
// what almost every caller wants. False is "does ANY record name it at
// all", which is now needed in exactly one place: distinguishing a config
// dir nobody has ever registered from one whose home record was deleted
// by hand, leaving orphaned sharers behind (see AddProvider's --share
// branch). They differ only once a shared record exists, and conflating
// them would let a shared record be reported as the home — arbitrarily,
// since the answer would then depend on org sort order.
//
// Neither mode answers "does org X name this dir": both return the FIRST
// match across all orgs, so a caller asking about one org gets an answer
// about another. That is the bug the --share matrix shipped with; use
// findConfigDirInOrg for that question instead.
func findConfigDirOwner(dir string, homeOnly bool) (org, providerID string, err error) {
	// An empty dir owns nothing and is owned by nothing. Without this, the
	// p.ConfigDir != dir comparison below matched every codex and local
	// record — all of which store "" — so ConfigDirHome("") named an
	// arbitrary unrelated provider as the home of a directory with no path.
	// `wakil provider add`'s shared-account notice printed exactly that.
	// Callers that hold a possibly-empty ConfigDir (providercmd.go's
	// runProviderAdd) should still check it themselves where they have a
	// better message; this is the floor under them, not a licence to skip it.
	if dir == "" {
		return "", "", nil
	}
	orgs, err := ListOrgs()
	if err != nil {
		return "", "", err
	}
	for _, o := range orgs {
		providers, _, err := listProvidersFor(o)
		if err != nil {
			return "", "", err
		}
		for _, p := range providers {
			if p.ConfigDir != dir {
				continue
			}
			// A shared record did not pin anything, so it cannot be the
			// home. It is still a real owner for the duplicate check,
			// which is why this is a parameter and not a fixed rule.
			if homeOnly && p.Shared {
				continue
			}
			return o, p.ID, nil
		}
	}
	return "", "", nil
}

// ConfigDirHome reports which org, and which of its providers, pinned
// WAKIL_ORG inside dir — the org a plain `claude` session started against
// that directory will run as, whatever else shares it. Returns "", "",
// nil when no org has claimed it.
//
// This is the question scripts/register-provider.sh has to ask before it
// runs `claude mcp add`: pinning a directory homed to another org would
// silently break that org's headless flow, which is the whole thing the
// one-dir-one-org rule was ever protecting.
func ConfigDirHome(dir string) (org, providerID string, err error) {
	return findConfigDirOwner(dir, true)
}

// ResolveProviderClaudePath answers "which binary does this record
// launch", which is not always the same question as "what does this
// record's claudePath field say".
//
// DERIVED FOR A SHARED RECORD, NOT COPIED INTO IT. A --share binding
// names a config dir another org homes: same account, same machine, same
// binary. Requiring the sharing record to repeat a value the homing
// record two directories away already carries is the papercut
// `shared-accounts-acceptance.md` D4 recorded — the add succeeds, and the
// window then refuses the selection with "the provider record is missing
// claudePath", which names a field the operator was never asked for.
//
// Deriving rather than copying at `provider add` follows
// ProviderTokenRef's reasoning directly: a copy is a second string that
// can disagree with the first, and it disagrees the day the binary moves.
// Inheriting keeps "one account, one binary" true by construction instead
// of true at registration time.
//
// The four answers, and why each is the one it is:
//
//   - A record with its own claudePath keeps it. Explicit beats inherited
//     whether the record is shared or not; nothing here overrides a value
//     the operator typed.
//   - A shared record with none inherits the homing record's.
//   - A record that is NOT shared keeps its empty value and returns no
//     error. It homes its own dir, so there is nothing above it to
//     inherit from, and the caller's existing "missing claudePath"
//     refusal is already the right message for it.
//   - A shared record whose home cannot supply one is refused HERE, by
//     name, because the record that needs fixing is in a different org
//     from the one the operator is looking at.
func ResolveProviderClaudePath(p Provider) (string, error) {
	if p.ClaudePath != "" || !p.Shared {
		return p.ClaudePath, nil
	}
	homeOrg, homeID, err := ConfigDirHome(p.ConfigDir)
	if err != nil {
		return "", err
	}
	if homeID == "" {
		// RemoveProvider refuses to orphan a share, so reaching this line
		// means ~/.wakil was edited by hand. Say that, rather than
		// reporting a missing field on a record that has no missing field.
		return "", UserError("provider " + strconv.Quote(p.ID) +
			" shares configDir " + strconv.Quote(p.ConfigDir) +
			", but no org homes that directory any more — the record that pinned it is gone." +
			" Re-register it in its home org, or re-add this provider with --claude-path")
	}
	home, err := LoadProviderFor(homeOrg, homeID)
	if err != nil {
		return "", err
	}
	if home.ClaudePath == "" {
		return "", UserError("provider " + strconv.Quote(p.ID) +
			" shares configDir " + strconv.Quote(p.ConfigDir) +
			" and carries no claudePath of its own, and neither does provider " +
			strconv.Quote(homeID) + " in org " + strconv.Quote(homeOrg) + ", which homes it." +
			" Set it on the homing record, or re-add this one with --claude-path")
	}
	return home.ClaudePath, nil
}

// findConfigDirInOrg reports which of org's OWN providers records dir as
// its configDir, shared or not, or "" when none does.
//
// This is the second of the two questions AddProvider has to ask, and it
// is a separate function rather than a third mode of findConfigDirOwner
// because it is a different question, not a filter on the same one:
// findConfigDirOwner scans every org and returns the first match, which
// is the wrong answer to "does THIS org already name this dir" whenever
// some other org names it too. One org's records are at most a handful
// of files, so scanning them separately costs nothing worth saving.
//
// It deliberately does NOT skip shared records: a shared record in this
// org still names this account once, and a second id for it is the
// duplicate the same-org rule refuses.
func findConfigDirInOrg(org, dir string) (providerID string, err error) {
	if dir == "" {
		return "", nil
	}
	providers, _, err := listProvidersFor(org)
	if err != nil {
		return "", err
	}
	for _, p := range providers {
		if p.ConfigDir == dir {
			return p.ID, nil
		}
	}
	return "", nil
}

// configDirSharers returns every (org, provider) pair OTHER than
// (homeOrg, homeID) that names dir, in ListOrgs order. It is what
// RemoveProvider consults before deleting a record that homes a config
// dir: those records depend on the home existing, and there is no other
// way to enumerate them.
func configDirSharers(dir, homeOrg, homeID string) ([]string, error) {
	if dir == "" {
		return nil, nil
	}
	orgs, err := ListOrgs()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, o := range orgs {
		providers, _, err := listProvidersFor(o)
		if err != nil {
			return nil, err
		}
		for _, p := range providers {
			if p.ConfigDir != dir || (o == homeOrg && p.ID == homeID) {
				continue
			}
			out = append(out, o+"/"+p.ID)
		}
	}
	return out, nil
}

// RemoveProvider deletes org's provider record for id. It refuses while
// that record homes a config dir other orgs still share, naming them —
// the same shape, and the same reason, as RemoveOrg refusing an org that
// still holds providers or projects (org.go): a deletion that strands a
// dependent is not undoable, and the dependents are nameable, so name
// them instead of performing it.
//
// WHY IT MATTERS HERE, because the stranded state is worse than it
// looks: the home record is the only thing that ties a config dir to the
// org whose WAKIL_ORG is pinned INSIDE it, and that pin is a file on
// disk this command does not touch. Delete the home and ConfigDirHome
// returns "" forever while the pin stays exactly where it was. From
// there `provider add` without --share is refused (some other org's
// record still names the dir), `--share` is refused (nothing homes it),
// `provider home` reports no home, and register-provider.sh — which asks
// `provider home` before every `claude mcp add` — can never run for that
// dir again. A one-way door out of every command that could repair it.
//
// Unlike RemoveOrg there is NO --force escape hatch, and that is the
// point rather than an omission: forcing it would re-open the same
// one-way door behind a flag, and the refusal already names a followable
// route out (remove the sharing records first, then this one). The only
// remaining ways to reach the orphaned state are `wakil org rm --force`
// on the homing org and deleting the record file by hand — both of which
// say plainly that they are deleting more than one record.
//
// Removing a SHARED record, or a record with no config dir at all, is
// unconditional: nothing depends on either.
//
// id is revalidated here rather than trusted from a prior AddProvider
// call: this package's convention (see OrgDirFor) is that anything about
// to become part of a filesystem path is checked at the point of use,
// not only at creation, so a caller-supplied id can never walk the
// resulting path outside providers/.
func RemoveProvider(org, id string) error {
	if err := validateProviderToken(id); err != nil {
		return err
	}
	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, id+".json")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return UserError("no provider " + strconv.Quote(id) + " in org " + strconv.Quote(org))
	}
	// Loaded rather than assumed: only the record itself says whether it
	// carries a config dir and whether it homed it. A record this package
	// cannot parse is deleted without the check — it is already invisible
	// to ConfigDirHome and to every other reader, so it can home nothing,
	// and refusing to delete an unreadable file would leave no way to
	// clear it at all.
	if p, err := LoadProviderFor(org, id); err == nil && p.ConfigDir != "" && !p.Shared {
		sharers, err := configDirSharers(p.ConfigDir, org, id)
		if err != nil {
			return err
		}
		if len(sharers) > 0 {
			return UserError("provider " + strconv.Quote(id) + " in org " + strconv.Quote(org) +
				" homes configDir " + strconv.Quote(p.ConfigDir) + ", which " +
				strconv.Itoa(len(sharers)) + " other record(s) still share: " + strings.Join(sharers, ", ") +
				" — removing it would leave them with no home for that directory," +
				" while the WAKIL_ORG pin inside it stays exactly where it is," +
				" and no `wakil provider add` could restore either." +
				" Remove the sharing record(s) first (wakil provider rm <id> --org <org> for each of: " +
				strings.Join(sharers, ", ") + "), then remove this one." +
				" Keychain credentials are never removed by any of this")
		}
	}
	return os.Remove(path)
}

// LoadProviderFor returns org's provider record for id.
//
// id is revalidated here for the same reason as in RemoveProvider: it
// reaches this function both from ListProvidersFor's own filenames
// (already safe) and from external callers such as CurrentProvider,
// which passes through whatever WAKIL_PROVIDER contains.
func LoadProviderFor(org, id string) (*Provider, error) {
	if err := validateProviderToken(id); err != nil {
		return nil, err
	}
	dir, err := providersDirFor(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(dir, id+".json"))
	if os.IsNotExist(err) {
		return nil, UserError("no provider " + strconv.Quote(id) + " in org " + strconv.Quote(org) +
			" — register it with: wakil provider add " + id + " --org " + org)
	}
	if err != nil {
		return nil, err
	}
	var p Provider
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, UserError("provider record " + strconv.Quote(id) + " is unreadable: " + err.Error())
	}
	p.ID = id
	return &p, nil
}

// ListProviders returns the current org's providers, sorted by id. It
// never returns a nil slice.
func ListProviders() ([]Provider, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return ListProvidersFor(org)
}

// ListProvidersFor returns org's providers, sorted by id. It never
// returns a nil slice: no providers directory is a legitimate, common
// case (nothing registered yet).
//
// A record it cannot parse is skipped rather than failing the whole
// listing — one corrupt file must not hide every other provider. This
// function discards which ids were skipped; callers that need to name an
// unreadable provider (sessions.go's ListSessions report) should call
// listProvidersFor directly instead.
func ListProvidersFor(org string) ([]Provider, error) {
	providers, _, err := listProvidersFor(org)
	return providers, err
}

// ProviderSummary is one row of `list_providers` (wakil-ctx) — the
// picker's own source, added by Phase 2b-vi Task 12 once acceptance
// found there was no way for the app to learn an org's provider set at
// all. It deliberately carries only what a human picking an account
// needs to see: an id and a kind, plus the label when one was set.
//
// **Never ConfigDir or ClaudePath, and never a credential.** Both are
// filesystem detail nobody choosing an account needs, and the OAuth
// token is never on Provider in the first place — it lives in the
// Keychain under ProviderTokenRef and is reachable only through `wakil
// provider credentials`, which this listing must never call (that verb
// exists precisely so nothing else has to). Confusing "list the
// providers" with "hand back a secret" is the one mistake this type
// exists to make structurally impossible: there is no field on it a
// caller could even try to leak.
//
// ID is a real field here, unlike on Provider itself — Provider.ID is
// `json:"-"` because the file's basename is the only copy of it that
// can never disagree with the record, but a listing has no filename for
// a client to fall back on, so the id has to travel on the wire or not
// travel at all.
type ProviderSummary struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Label string `json:"label,omitempty"`
}

// ProviderListing is `list_providers`' wire format: an array, not the
// map-keyed-by-name shape `ProjectListing` uses for `list_projects`.
// The two commands read as if they should agree, but a project's
// registry key and its `project.json` name can differ (`ProjectEntry`
// has no name field of its own — Resolved.go's `providerReport` doc
// comment spells out why the join has to be by path instead) while a
// provider's id genuinely IS its only name, so there is no second name
// for a map key to protect against disagreeing with. An array is the
// plainer shape and nothing here needs the dictionary's free
// deduplication.
type ProviderListing struct {
	// Providers is never nil, matching ProjectListing.Projects and
	// SessionList.Sessions: an org with none registered marshals to []
	// on the wire, not null, so a client's array decoder never has to
	// special-case "no providers yet" as a parse failure.
	Providers []ProviderSummary `json:"providers"`
}

// ListProvidersForCurrentOrg is `list_providers`' backing call — the
// org-resolving wrapper `ListProvidersFor(org)` itself does not supply,
// mirroring the pair `ListProjectsForOrg` (no arg, resolves CurrentOrg)
// and `LoadRegistryFor` (org, does not) already make for projects. Like
// `ListProjectsForOrg`, it degrades to an empty (never nil) listing
// alongside the error, so a handler that only cares about the success
// path never has to nil-check before ranging over it.
func ListProvidersForCurrentOrg() (ProviderListing, error) {
	org, err := CurrentOrg()
	if err != nil {
		return ProviderListing{Providers: []ProviderSummary{}}, err
	}
	providers, err := ListProvidersFor(org)
	if err != nil {
		return ProviderListing{Providers: []ProviderSummary{}}, err
	}
	out := make([]ProviderSummary, 0, len(providers))
	for _, p := range providers {
		out = append(out, ProviderSummary{ID: p.ID, Kind: p.Kind, Label: p.Label})
	}
	return ProviderListing{Providers: out}, nil
}

// listProvidersFor is ListProvidersFor's implementation, additionally
// returning the ids of any provider.json files it could not parse. A
// record that fails to unmarshal never becomes a Provider value, so the
// only way to name it at all is to hand back the id directly — nothing
// downstream can reconstruct it from the (necessarily incomplete)
// providers slice.
func listProvidersFor(org string) (providers []Provider, skipped []string, err error) {
	dir, err := providersDirFor(org)
	if err != nil {
		return nil, nil, err
	}
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return []Provider{}, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	out := []Provider{}
	var bad []string
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".json")
		p, err := LoadProviderFor(org, id)
		if err != nil {
			bad = append(bad, id)
			continue
		}
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, bad, nil
}

// MachineProvider is one account as seen from OUTSIDE any single org:
// which org's record names it, and which org homes the config dir.
//
// It carries no credential and must not grow one. The token lives in the
// Keychain and comes back only from `wakil provider credentials`, for the
// one provider actually being switched to — the rule ctx_list_providers'
// own description already states.
type MachineProvider struct {
	Org       string `json:"org"`
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Label     string `json:"label,omitempty"`
	ConfigDir string `json:"configDir,omitempty"`
	// HomeOrg is the org whose record PINS WAKIL_ORG inside ConfigDir.
	// It differs from Org exactly when this record is a --share binding,
	// and the plane shows the difference because it is the genuinely
	// surprising thing about a shared account: a plain `claude` session
	// started in that directory runs as HomeOrg, not Org.
	HomeOrg string `json:"homeOrg,omitempty"`
}

// ListAllProviders enumerates every (org, provider) pair on this machine.
//
// Reading across orgs is established practice, not a new power this
// introduces: AddProvider has always scanned every org to enforce the
// config-dir rules (findConfigDirOwner), which is how a shared directory
// is detected at all. What is new is exposing the enumeration, which is
// why the tool wrapping this is operator-only (spec §9.1).
//
// Best-effort per org: one unreadable org must not blank the list, for
// the same reason listOrgs is best-effort per row.
func ListAllProviders() ([]MachineProvider, error) {
	orgs, err := ListOrgs()
	if err != nil {
		return nil, err
	}
	out := []MachineProvider{}
	for _, org := range orgs {
		ps, err := ListProvidersFor(org)
		if err != nil {
			continue
		}
		for _, p := range ps {
			row := MachineProvider{
				Org: org, ID: p.ID, Kind: p.Kind,
				Label: p.Label, ConfigDir: p.ConfigDir,
			}
			if p.ConfigDir != "" {
				if homeOrg, _, err := ConfigDirHome(p.ConfigDir); err == nil {
					row.HomeOrg = homeOrg
				}
			}
			out = append(out, row)
		}
	}
	return out, nil
}

// CurrentProvider returns the provider id this process was launched as,
// or "" when the launcher did not declare one.
//
// Unset is legitimate and must stay so: the operator runs `wakil secrets
// set` by hand, where the launcher is a human and there is no provider
// at all. When it IS set it must name a registered provider, for the
// same typo reason WAKIL_ORG must name a registered org.
func CurrentProvider() (string, error) {
	id := os.Getenv("WAKIL_PROVIDER")
	if id == "" {
		return "", nil
	}
	org, err := CurrentOrg()
	if err != nil {
		return "", err
	}
	if _, err := LoadProviderFor(org, id); err != nil {
		return "", err
	}
	return id, nil
}
