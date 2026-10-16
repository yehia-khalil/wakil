package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
)

// ProjectEntry is one row of an org's project registry.
//
// Provider names which of the org's providers should work on this
// project. It is a PREFERENCE, never a binding: nothing headless can
// enforce it, because by the time a Wakil server is running the provider
// has already launched it. providerReport (resolve.go) reads this field
// to build the match report get_context returns, and only ever reports a
// mismatch — it never blocks on one, per §7 of the org/provider
// decoupling design. A binding would fire hardest exactly when the
// operator is rate-limited and reaching for the backup account, which is
// the case the preference exists to make easy.
type ProjectEntry struct {
	Path     string `json:"path"`
	Provider string `json:"provider,omitempty"`
}

// registryFileName is declared in org.go, which needs it for RemoveOrg's
// dependant count. Do not redeclare it here.

// LoadRegistry loads the current org's project registry. See
// LoadRegistryFor for the on-disk behaviour.
func LoadRegistry() (map[string]ProjectEntry, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return LoadRegistryFor(org)
}

// LoadRegistryFor loads org's project registry from
// ~/.wakil/orgs/<org>/projects.json. A registered org with no registry
// file yet returns an empty, non-nil map rather than an error: an org
// with no projects is a legitimate, common state.
func LoadRegistryFor(org string) (map[string]ProjectEntry, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(dir, registryFileName))
	if os.IsNotExist(err) {
		return map[string]ProjectEntry{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]ProjectEntry{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, UserError("projects.json for org " + strconv.Quote(org) + " is unreadable: " + err.Error())
	}
	return m, nil
}

// SaveRegistry writes org's project registry.
//
// It marshals with json.MarshalIndent, which is load-bearing beyond
// formatting: RemoveOrg (org.go) decides whether an org still holds
// projects by testing whether projects.json is larger than len("{}"),
// and MarshalIndent of an empty map emits exactly "{}". A different
// marshaller would silently break that check.
func SaveRegistry(org string, reg map[string]ProjectEntry) error {
	dir, err := OrgDirFor(org)
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, registryFileName), b)
}

// MisfiledProject is a registry entry whose project.json declares a
// different org than the registry it was found in. The project's own
// project.json is authoritative for org (see ListProjectsForOrg); this
// records the disagreement so an operator can fix whichever side is
// wrong instead of the project silently vanishing from the listing.
type MisfiledProject struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	FiledUnder  string `json:"filedUnder"`
	DeclaredOrg string `json:"declaredOrg"`
}

// ProjectListing is what list_projects returns.
type ProjectListing struct {
	// Projects is never nil, so an org with none marshals to {}.
	Projects map[string]ProjectEntry `json:"projects"`

	// Misfiled names entries whose project.json declares another org.
	// Reporting rather than silently skipping is the point: before the
	// registry was per-org, such a project simply vanished from the
	// listing with nothing to explain why.
	Misfiled []MisfiledProject `json:"misfiled,omitempty"`

	// Unreadable names entries whose project.json could not be read at
	// all. Same house invariant as SessionList.Skipped and
	// IssuePage.Truncated: carry the partiality signal with the data.
	// It is a distinct field from Misfiled because "could not read the
	// project file" and "the project file names another org" are
	// different statements.
	Unreadable []string `json:"unreadable,omitempty"`
}

// ListProjectsForOrg lists the current org's projects.
//
// The project's own project.json is AUTHORITATIVE for org. Registry
// placement is an index, not an assertion of ownership — if placement
// won, Resolve()'s proj.Org != CurrentOrg() check would be comparing the
// ambient org against a value derived from the directory that ambient org
// already selected, which is a value compared against itself and
// destroys the cross-org guard.
func ListProjectsForOrg() (ProjectListing, error) {
	org, err := CurrentOrg()
	if err != nil {
		return ProjectListing{Projects: map[string]ProjectEntry{}}, err
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return ProjectListing{Projects: map[string]ProjectEntry{}}, err
	}
	out := ProjectListing{Projects: map[string]ProjectEntry{}}
	for name, entry := range reg {
		proj, err := LoadProject(entry.Path)
		if err != nil {
			out.Unreadable = append(out.Unreadable, name)
			continue
		}
		if proj.Org != org {
			out.Misfiled = append(out.Misfiled, MisfiledProject{
				Name: name, Path: entry.Path, FiledUnder: org, DeclaredOrg: proj.Org,
			})
			continue
		}
		out.Projects[name] = entry
	}
	sort.Slice(out.Misfiled, func(i, j int) bool { return out.Misfiled[i].Name < out.Misfiled[j].Name })
	sort.Strings(out.Unreadable)
	return out, nil
}
