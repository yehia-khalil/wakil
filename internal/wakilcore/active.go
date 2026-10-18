package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
)

type ActiveContext struct {
	Project     string `json:"project"`
	Environment string `json:"environment"`
	// Provider is the active context's fourth axis: which of the org's
	// registered providers (internal/wakilcore/provider.go) the operator
	// has actually picked to run against, independent of the project's
	// declared default and independent of whatever WAKIL_PROVIDER the
	// current process happened to launch under (Resolved.Provider.Running
	// reports that latter, launch-time fact; this field is the persisted,
	// pick-time one a provider switch changes without a relaunch).
	//
	// omitempty, and its absence is read as "" rather than an error: every
	// active.json written before this field existed has no "provider" key
	// at all, and that file must go on parsing exactly as it did before —
	// an operator upgrading wakil-ctx must not wake up to a broken active
	// context on an org they have not touched today.
	Provider string `json:"provider,omitempty"`
}

// activePath returns the active-context file for the CURRENT org.
//
// Safety does not rest on the per-org split. Resolve() re-checks
// proj.Org against CurrentOrg() on every call regardless of which file
// the context came from; that check is the cross-org boundary.
func activePath() (string, error) {
	dir, err := OrgDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "active.json"), nil
}

// PinnedPlace returns the project name (WAKIL_PROJECT) and environment
// (WAKIL_ENVIRONMENT) this process was launched pinned to. Each is "" when
// its variable is unset or empty. A pinned process (a background agent
// kept on the place it started in) resolves against these instead of
// active.json, which the operator keeps changing underneath it.
func PinnedPlace() (project string, environment string) {
	return os.Getenv("WAKIL_PROJECT"), os.Getenv("WAKIL_ENVIRONMENT")
}

// ErrPinned is the refusal a pinned process gets when it tries to switch
// an axis its launcher fixed.
func ErrPinned() error {
	project, environment := PinnedPlace()
	return UserError("this process's place is pinned to " + project + "/" + environment + " — it cannot switch project or environment")
}

// ReadActive returns the current org's active context, with this process's
// pinned place (PinnedPlace) laid over it: a pinned project name is looked
// up in the org's registry and replaces Project with that entry's
// project.json path, and then Environment is WAKIL_ENVIRONMENT alone ("" if
// unset) — the file's environment belongs to the project on screen, not the
// pinned one. With only the environment pinned, it replaces the file's.
// Provider always comes from the file. A missing file is an ordinary state — no
// project set yet — not an error.
//
// Pinning never bypasses Invariant 4: the pinned project's project.json is
// still checked against the current org by Resolve().
func ReadActive() (ActiveContext, error) {
	a, err := ReadActiveUnpinned()
	if err != nil {
		return ActiveContext{}, err
	}
	project, environment := PinnedPlace()
	if project != "" {
		reg, err := LoadRegistry()
		if err != nil {
			return ActiveContext{}, err
		}
		entry, ok := reg[project]
		if !ok {
			return ActiveContext{}, UserError("pinned project " + strconv.Quote(project) + " is not registered in this org")
		}
		a.Project = entry.Path
		a.Environment = environment
	} else if environment != "" {
		a.Environment = environment
	}
	return a, nil
}

// ReadActiveUnpinned returns the file's own active context, ignoring the
// pins. It is for read-modify-write of the file (a provider switch), which
// must not copy a pinned process's place into the operator's active.json.
func ReadActiveUnpinned() (ActiveContext, error) {
	path, err := activePath()
	if err != nil {
		return ActiveContext{}, err
	}
	a, _, err := readActiveFile(path)
	return a, err
}

// readActiveFile reads one active-context file. found is false when the
// file does not exist, which is an ordinary state (no project set yet)
// and not an error.
func readActiveFile(path string) (ActiveContext, bool, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return ActiveContext{}, false, nil
	}
	if err != nil {
		return ActiveContext{}, false, err
	}
	var parsed ActiveContext
	if err := json.Unmarshal(b, &parsed); err != nil {
		return ActiveContext{}, false, err
	}
	return parsed, true, nil
}

// WriteActive persists the active context for the CURRENT org, replacing
// the file atomically so a crash mid-write cannot leave a truncated one,
// and so two writers in the same org (two Claude sessions, ordinary use)
// cannot tear each other's write — see writeFileAtomic in paths.go for
// why the replacement uses a per-call temp file rather than a fixed one.
func WriteActive(a ActiveContext) error {
	path, err := activePath()
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(a, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}
