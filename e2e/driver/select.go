package driver

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

// The three ways a run's file list is chosen. The runbook reads the mode to
// tell "owed to the full run" from "never run".
const (
	SelectModeSelected = "selected"
	SelectModeNamed    = "named"
	SelectModeFull     = "full"
)

// AlwaysSelected runs on every selected run: the cheapest launch, it proves
// the bundle starts and refreshes the action denominator `e2e-cover` refuses
// to read stale.
const AlwaysSelected = CheckRoot + "unseeded/org-plane.jsonl"

// ChangedFile is one path the branch changed, with its text on both sides.
// Before is empty for an addition, After for a deletion.
type ChangedFile struct {
	Path   string
	Status string
	Before string
	After  string
}

// Pick is one selected check and every reason it was selected.
type Pick struct {
	Check   string   `json:"check"`
	Reasons []string `json:"reasons"`
}

// Selection is which checks a run took, and why — and, as loudly, which
// changed files no check reaches.
type Selection struct {
	Mode       string    `json:"mode"`
	BaseCommit string    `json:"baseCommit,omitempty"`
	HeadCommit string    `json:"headCommit"`
	Dirty      bool      `json:"dirty,omitempty"`
	SelectedAt time.Time `json:"selectedAt"`
	Picks      []Pick    `json:"picks"`
	// Unmapped files reach no check and are owed to the full run.
	Unmapped []string `json:"unmapped,omitempty"`
	// NoCheck files declare identifiers no check presses: the coverage
	// gate's question, listed apart so it is not mistaken for unmapped.
	NoCheck []string `json:"mappedNoCheck,omitempty"`
	// Ignored files cannot change what a check sees.
	Ignored []string `json:"ignored,omitempty"`
}

// SelectChecks maps a branch's changed files to the checks they reach.
//
// **Through what the harness already reads, and nothing else**: a check file
// selects itself, an identifier selects the checks that press it, a quoted
// action name selects the checks that dispatch it. A file none of those reach
// is listed as unmapped and left to `make e2e-full`, never escalated to it —
// shared code reaches every check, and escalating would put the whole suite
// back on most branches.
func SelectChecks(changes []ChangedFile, corpus map[string]Check) Selection {
	sel := Selection{Mode: SelectModeSelected}
	reasons := map[string][]string{}
	pick := func(file, reason string) {
		if !slices.Contains(reasons[file], reason) {
			reasons[file] = append(reasons[file], reason)
		}
	}
	if _, ok := corpus[AlwaysSelected]; ok {
		pick(AlwaysSelected, "always: proves the bundle starts and records the actions e2e-cover reads")
	}

	covers := make(map[string]Coverage, len(corpus))
	actions := map[string]bool{}
	for file, check := range corpus {
		covers[file] = CoverageOf([]Check{check})
		for _, action := range covers[file].Dispatched() {
			actions[action] = true
		}
	}
	checkFiles := keysOf(covers)
	actionNames := keysOf(actions)

	for _, change := range changes {
		switch {
		case ignoredPath(change.Path):
			sel.Ignored = append(sel.Ignored, change.Path)
		case isCheckFile(change.Path):
			// A deleted check is not in the corpus: nothing to run, nothing owed.
			if _, ok := corpus[change.Path]; ok {
				pick(change.Path, "the check changed")
			}
		case path.Ext(change.Path) == ".swift":
			base := path.Base(change.Path)
			hit := false
			identifiers := append(IdentifiersIn(base, change.Before), IdentifiersIn(base, change.After)...)
			for _, identifier := range identifiers {
				for _, file := range checkFiles {
					if covers[file].Exercises(identifier.Name) {
						pick(file, fmt.Sprintf("%s declares %s", base, identifier.Name))
						hit = true
					}
				}
			}
			code := Sources{text: withoutCommentLines(change.Before) + "\n" + withoutCommentLines(change.After)}
			for _, action := range actionNames {
				if !code.Mentions(action) {
					continue
				}
				for _, file := range checkFiles {
					if covers[file].Dispatches(action) {
						pick(file, fmt.Sprintf("%s spells action %s", base, action))
						hit = true
					}
				}
			}
			switch {
			case hit:
			case len(identifiers) > 0:
				sel.NoCheck = append(sel.NoCheck, change.Path)
			default:
				sel.Unmapped = append(sel.Unmapped, change.Path)
			}
		default:
			sel.Unmapped = append(sel.Unmapped, change.Path)
		}
	}

	for file, why := range reasons {
		sel.Picks = append(sel.Picks, Pick{Check: file, Reasons: why})
	}
	sortPicks(sel.Picks)
	sort.Strings(sel.Unmapped)
	sort.Strings(sel.NoCheck)
	sort.Strings(sel.Ignored)
	return sel
}

// Has reports whether this selection picked the file.
func (s Selection) Has(file string) bool {
	for _, p := range s.Picks {
		if sameCheckFile(p.Check, file) {
			return true
		}
	}
	return false
}

// Files lists the picks in launch order, which is the order they run in.
func (s Selection) Files() []string {
	files := make([]string, 0, len(s.Picks))
	for _, p := range s.Picks {
		files = append(files, p.Check)
	}
	return files
}

func isCheckFile(file string) bool {
	return strings.HasPrefix(file, CheckRoot) && path.Ext(file) == ".jsonl"
}

// ignoredPath reports a file that cannot change what a check sees: prose,
// committed proofs, and tests, which never reach the bundle.
func ignoredPath(file string) bool {
	return strings.HasPrefix(file, "docs/") ||
		strings.HasPrefix(file, CheckRoot+"proofs/") ||
		strings.HasPrefix(file, "app/Tests/") ||
		strings.HasSuffix(file, "_test.go") ||
		path.Ext(file) == ".md"
}

// launchRank orders files unseeded, seeded, agent — `launchDirs`' order — and
// anything else last.
func launchRank(file string) int {
	for rank, dir := range LaunchDirs() {
		if strings.HasPrefix(file, dir) {
			return rank
		}
	}
	return len(LaunchDirs())
}

func sortPicks(picks []Pick) {
	sort.Slice(picks, func(i, j int) bool {
		ri, rj := launchRank(picks[i].Check), launchRank(picks[j].Check)
		if ri != rj {
			return ri < rj
		}
		return picks[i].Check < picks[j].Check
	})
}

func keysOf[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// NamedSelection is a run whose files were chosen by hand (`E2E_ONLY`) or are
// the whole corpus (`make e2e-full`). Every file must exist and sit in a
// launch directory: a glob that matched nothing arrives as itself, and running
// an empty or misplaced set would pass having proved nothing.
func NamedSelection(mode string, files []string) (Selection, error) {
	if len(files) == 0 {
		return Selection{}, fmt.Errorf("no check files named, so nothing would run")
	}
	reason := "named by E2E_ONLY"
	if mode == SelectModeFull {
		reason = "full run"
	}
	sel := Selection{Mode: mode}
	for _, named := range files {
		file := filepath.Clean(named)
		info, err := os.Stat(file)
		if err != nil {
			return Selection{}, fmt.Errorf("%s: %w", named, err)
		}
		if !info.Mode().IsRegular() || path.Ext(file) != ".jsonl" {
			return Selection{}, fmt.Errorf("%s is not a check file", named)
		}
		if sel.Has(file) {
			continue
		}
		if _, ok := LaunchFor(file); !ok {
			return Selection{}, fmt.Errorf("%s is in none of %s, so there is no way to know which launch it wants",
				file, strings.Join(LaunchDirs(), ", "))
		}
		sel.Picks = append(sel.Picks, Pick{Check: file, Reasons: []string{reason}})
	}
	sortPicks(sel.Picks)
	return sel, nil
}
