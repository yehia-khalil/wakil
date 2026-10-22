package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Org is the per-organisation record, stored at
// ~/.wakil/orgs/<org>/org.json.
//
// The org id itself is NOT a field: it is the directory name, so there is
// one place it can be written and no way for the two to disagree.
type Org struct {
	DisplayName string `json:"displayName,omitempty"`

	// JiraBase is the org's Jira site. It lives here rather than being
	// passed at registration because an org may have several providers,
	// and N registrations stating one fact is N chances for two of them to
	// disagree with nothing to catch it. Stored normalised, so every
	// reader gets the same string.
	JiraBase string `json:"jiraBase,omitempty"`

	// DefaultProvider is used for projects that name no provider of their
	// own. Advisory only — see Resolved.Provider; nothing is ever blocked
	// because of it.
	DefaultProvider string `json:"defaultProvider,omitempty"`

	// SpeechProvider names the speech-to-text engine this organization's
	// windows listen with (2d-ii; Decision 18, Invariant 11). Empty means
	// the default, Apple. Go does not validate it against a list: which
	// engines exist is the app's knowledge, and the app falls back to
	// Apple and says so when the id is one it does not know.
	SpeechProvider string `json:"speechProvider,omitempty"`

	// QuickProvider is the provider quick tasks run on (3b-viii, Decision 42);
	// empty means the active provider.
	QuickProvider string `json:"quickProvider,omitempty"`

	// GitName and GitEmail are the author identity every commit from Wakil
	// uses (3a-ii, Decision 43). Empty falls back to git config.
	GitName  string `json:"gitName,omitempty"`
	GitEmail string `json:"gitEmail,omitempty"`

	// GhostText and FastPath switch the org's quick tasks (3b-ix, Decision 42 amended). Nil is
	// the default, resolved on config_tree: ghost-text falls back to the app-wide setting, then
	// on; the fast path is on when QuickProvider names a local provider.
	GhostText *bool `json:"ghostText,omitempty"`
	FastPath  *bool `json:"fastPath,omitempty"`
	// CommitDrafts switches the commit box's ✨ (3a-ii-b). Nil is the default, on.
	CommitDrafts *bool `json:"commitDrafts,omitempty"`

	// GitAccounts are the organisation's git accounts, one per host (3a-iii, Decision 44); their
	// secrets are in the Keychain, never here. PullStrategy is how Pull and Sync integrate:
	// rebase (the default when empty), merge or ff-only.
	GitAccounts  []GitAccount `json:"gitAccounts,omitempty"`
	PullStrategy string       `json:"pullStrategy,omitempty"`
	// LastCloneFolder is the folder the operator last cloned into: the only one the agent may.
	LastCloneFolder string `json:"lastCloneFolder,omitempty"`

	// Agent instructions (3a-iii-b, Decision 45): appended after Wakil's own rules when an agent's
	// session starts, General first, then Commits and Pull requests.
	AgentGeneral          string `json:"agentGeneral,omitempty"`
	GitCommitInstructions string `json:"gitCommitInstructions,omitempty"`
	GitPRInstructions     string `json:"gitPRInstructions,omitempty"`
}

const orgFileName = "org.json"

// registryFileName is the per-org project registry filename, under
// orgs/<org>/projects.json. Declared here because RemoveOrg needs it to
// check for dependants; registry.go reuses this constant rather than
// redeclaring it.
const registryFileName = "projects.json"

// LoadOrg returns the current org's record.
func LoadOrg() (*Org, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return LoadOrgFor(org)
}

// LoadOrgFor returns org's record. A registered org with no org.json yet
// is not an error: it returns an empty *Org.
func LoadOrgFor(org string) (*Org, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(dir, orgFileName))
	if os.IsNotExist(err) {
		// The directory exists but the record does not. Treat it as an
		// empty record rather than an error: an org with no Jira site and
		// no default provider is a legitimate configuration, and the
		// directory's existence is what "registered" means.
		return &Org{}, nil
	}
	if err != nil {
		return nil, err
	}
	var o Org
	if err := json.Unmarshal(b, &o); err != nil {
		return nil, UserError("org.json for org " + strconv.Quote(org) + " is unreadable: " + err.Error())
	}
	return &o, nil
}

// CreateOrg registers a new org. It refuses to overwrite an existing one:
// an accidental re-create would silently drop that org's jiraBase and
// defaultProvider, and the operator would not find out until a Jira call
// failed.
//
// The org's directory is created BEFORE normaliseOrg runs, which is the
// reverse of the general rule elsewhere in this file of failing before
// touching disk. normaliseOrg's defaultProvider check (see its own doc
// comment) needs LoadProviderFor to find the org's providers/ directory,
// which cannot exist before orgDirCreate makes it. A rejected value rolls
// the directory back rather than leaving a half-made org on disk — see
// TestCreateOrgRefusesBadJiraBase, which pins that property directly.
//
// One consequence: `wakil org create <org> --default-provider X` can
// never succeed, because X cannot already be registered under an org
// that does not exist yet. That is intentional — it mirrors the rule
// `wakil provider add` already imposes on every OTHER caller of a
// provider id — and docs/wakil/operator-todo.md's rebuild procedure
// already creates orgs (step 2) before adding providers (step 3), so it
// never asks an operator to hit this order.
func CreateOrg(org string, o Org) error {
	if err := validateOrgToken(org); err != nil {
		return err
	}
	if _, err := OrgDirFor(org); err == nil {
		return UserError("org " + strconv.Quote(org) + " already exists")
	}
	dir, err := orgDirCreate(org)
	if err != nil {
		return err
	}
	normalised, err := normaliseOrg(org, o)
	if err != nil {
		_ = os.RemoveAll(dir)
		return err
	}
	if err := writeOrgFile(dir, normalised); err != nil {
		_ = os.RemoveAll(dir)
		return err
	}
	return nil
}

// SaveOrg updates an existing org's record. It requires the org to exist
// already — creation goes through CreateOrg so the "already exists"
// check has exactly one home.
func SaveOrg(org string, o Org) error {
	dir, err := OrgDirFor(org)
	if err != nil {
		return err
	}
	normalised, err := normaliseOrg(org, o)
	if err != nil {
		return err
	}
	return writeOrgFile(dir, normalised)
}

// normaliseOrg validates and normalises an Org record before it is
// written: JiraBase through normalizeJiraBase (jira.go), DefaultProvider
// as a usable provider-style token that additionally names a provider
// actually registered under org — spec §4.1 requires DefaultProvider,
// when set, to name a REGISTERED provider, the same rule LoadProviderFor
// already enforces on every other caller of a provider id (CurrentProvider,
// `wakil provider config-dir`, ...). Before this check, a typo'd
// defaultProvider on `org create`/`org set` was accepted silently and
// surfaced only much later, and confusingly: providerReport (resolve.go)
// adopts an unqualified DefaultProvider as-is into ProviderReport.Selected,
// so get_context would report a "selected" provider that never actually
// existed, with no hint that the fix is a typo in org.json rather than
// something wrong with whichever provider is really running.
func normaliseOrg(org string, o Org) (Org, error) {
	if o.JiraBase != "" {
		// "--jira-base" here because normaliseOrg is reached only from
		// CreateOrg and SaveOrg, both of which cmd/wakil's org create/set
		// populate exclusively from that flag — see finding 5 of the
		// final review: a hardcoded "WAKIL_JIRA_BASE" in normalizeJiraBase
		// used to send an operator who typed a bad --jira-base value off
		// to fix an environment variable they never set.
		base, err := normalizeJiraBase(o.JiraBase, "--jira-base")
		if err != nil {
			return Org{}, err
		}
		o.JiraBase = base
	}
	if o.DefaultProvider != "" {
		// Shape first, via validateProviderToken rather than
		// validateOrgToken: a provider id and an org id share the exact
		// same filename/Keychain-token constraints, but validateOrgToken's
		// message calls a bad value an "org id", which is simply wrong
		// for a value that came in through --default-provider and reads
		// as self-contradictory next to the "defaultProvider" prefix that
		// used to wrap it.
		if err := validateProviderToken(o.DefaultProvider); err != nil {
			return Org{}, UserError("defaultProvider: " + err.Error())
		}
		// Then existence: a shape-valid id that names no provider actually
		// registered under org is exactly as unusable as a malformed one,
		// and LoadProviderFor already raises the right message for it
		// ("no provider ... — register it with: wakil provider add ...").
		if _, err := LoadProviderFor(org, o.DefaultProvider); err != nil {
			return Org{}, err
		}
	}
	o.QuickProvider = strings.TrimSpace(o.QuickProvider)
	if o.QuickProvider != "" {
		if err := validateProviderToken(o.QuickProvider); err != nil {
			return Org{}, UserError("quickProvider: " + err.Error())
		}
		if _, err := LoadProviderFor(org, o.QuickProvider); err != nil {
			return Org{}, err
		}
	}
	o.SpeechProvider = strings.TrimSpace(o.SpeechProvider)
	if strings.ContainsAny(o.GitName+o.GitEmail, "\r\n") {
		return Org{}, UserError("gitName and gitEmail cannot hold a newline")
	}
	switch o.PullStrategy {
	case "", "rebase", "merge", "ff-only":
	default:
		return Org{}, UserError("pullStrategy is rebase, merge or ff-only")
	}
	return o, nil
}

// OrgGitIdentity is the author identity the organisation names; zero when
// it names none, so the caller falls back to git config.
func OrgGitIdentity(o *Org) GitIdentity {
	if o == nil {
		return GitIdentity{}
	}
	return GitIdentity{Name: o.GitName, Email: o.GitEmail}
}

func writeOrgFile(dir string, o Org) error {
	b, err := json.MarshalIndent(o, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, orgFileName), b)
}

// ListOrgs returns every registered org's id, sorted. It never returns a
// nil slice — an empty result is a legitimate, common case (nothing
// registered yet) and callers should not need a nil check to range over
// it.
func ListOrgs() ([]string, error) {
	root, err := OrgsDir()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, e := range entries {
		if e.IsDir() && orgFileTokenPattern.MatchString(e.Name()) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

// RemoveOrg deletes an org's whole directory. It refuses while the org
// still holds providers or projects unless forced, because those are the
// two things that make an org non-empty and the deletion is not undoable.
//
// It never touches the Keychain. A credential that outlives its org is
// recoverable; a deleted one is not.
func RemoveOrg(org string, force bool) error {
	dir, err := OrgDirFor(org)
	if err != nil {
		return err
	}
	if !force {
		// Counted off the filesystem rather than through ListProvidersFor,
		// so this file does not depend on that package-level function —
		// but filtered with the EXACT same predicate listProvidersFor
		// (provider.go) uses, so this count agrees with `wakil provider
		// list`: skip directories and anything not named "*.json". Without
		// that filter a stray subdirectory, or a dotfile dropped in
		// providers/ by an editor or a backup tool, inflated this count
		// past what provider list would ever show.
		//
		// A ".json" file that fails to PARSE still counts, deliberately:
		// this loop only checks the name, never opens the file, so an
		// unparseable record is indistinguishable here from a good one —
		// "unreadable" must never read as "absent" on a delete path.
		entries, err := os.ReadDir(filepath.Join(dir, "providers"))
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		providerCount := 0
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
				continue
			}
			providerCount++
		}
		hasProjects := false
		if fi, err := os.Stat(filepath.Join(dir, registryFileName)); err == nil && fi.Size() > int64(len("{}")) {
			hasProjects = true
		}
		if providerCount > 0 || hasProjects {
			return UserError(fmt.Sprintf("org %s still holds %d provider record(s)%s — re-run with --force to delete the whole org directory. Keychain credentials are never removed.",
				strconv.Quote(org), providerCount, map[bool]string{true: " and a project registry", false: ""}[hasProjects]))
		}
	}
	return os.RemoveAll(dir)
}
