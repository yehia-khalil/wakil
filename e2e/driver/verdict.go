package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"time"
)

// DefaultVerdictRoot is where the failability record is left.
//
// **A fixed, known path, because the Cover rung has to find it without being
// told.** A record whose location depends on the run is a record nobody
// reads, and a rung whose evidence nobody reads is the ceremony this ladder
// keeps deleting.
const DefaultVerdictRoot = ".context/e2e/new"

// CheckVerdict is one check's failability, and the reason for it.
type CheckVerdict struct {
	Name string `json:"name"`
	File string `json:"file"`
	// Seed is the fixture state the check ran in, and Agent says the launch
	// carried the scripted agent. A reader of this record has to be able to
	// tell which launch produced it: a check proved red in an instance with no
	// agent would be red for a reason that has nothing to do with the agent.
	Seed  bool `json:"seed"`
	Agent bool `json:"agent,omitempty"`
	// Launch names the kind in one word, so a reader does not have to decode
	// two booleans to learn which of the three produced this result.
	Launch string `json:"launch,omitempty"`
	// Red is the verdict this target wants: the check failed against the base
	// build, so it is testing something that build did not have.
	Red bool `json:"red"`
	// Missing reports that the run never reported this check at all —
	// quarantined, or not loaded. It is neither red nor green.
	Missing bool `json:"missing,omitempty"`
	// Redirected reports that this run did not try to prove the check at all:
	// it is backfill, and Reason says where it WAS seen to fail.
	//
	// **Recorded rather than only printed.** This record is what the Cover
	// rung reads without being told where to look, and a redirect that lived
	// only in stdout left it claiming the branch had no checks at all.
	Redirected bool     `json:"redirected,omitempty"`
	Reason     string   `json:"reason,omitempty"`
	Assertions int      `json:"assertions"`
	Failures   []string `json:"failures,omitempty"`
}

// Verdict is the record a red-required run leaves behind.
//
// **It records the reasons, not only the verdicts.** A reader has to be able
// to tell a check that failed on its own assertion from one that failed
// because the harness could not reach the window — the second is red against
// anything and proves nothing at all.
type Verdict struct {
	GeneratedAt time.Time `json:"generatedAt"`
	// BaseRef is what the base was resolved from — `origin/main`, or a commit
	// named by hand.
	BaseRef    string `json:"baseRef,omitempty"`
	BaseCommit string `json:"baseCommit"`
	HeadCommit string `json:"headCommit"`
	// Dirty reports that the working tree carried uncommitted changes when
	// this was written, so the checks that ran are not the checks in the
	// commit. Recorded rather than refused: an operator iterating on a check
	// runs this target constantly, and a record that says "not the commit" is
	// more use than no record.
	Dirty bool `json:"dirty,omitempty"`
	// Note carries a run that proved nothing, in words — a branch with no new
	// checks, most often.
	Note string `json:"note,omitempty"`
	// Fatal carries a fault in a RUN rather than in what it observed — a
	// stale quarantine entry, a launch that executed no check.
	//
	// **It is consulted before any check's verdict, and inverted by nothing.**
	// Everything going red because the harness could not work looks identical
	// to success from inside a red-required pass, and that is the one outcome
	// this record must never report as one.
	Fatal  []string       `json:"fatal,omitempty"`
	Checks []CheckVerdict `json:"checks"`
}

// Add records what one launch did.
//
// **The group's check gets a row even when the run never reported it.** An
// absent row reads as a check nobody wrote, which is exactly the state this
// record exists to distinguish from a check that was proved.
func (v *Verdict) Add(group Group, result Result) {
	v.Fatal = append(v.Fatal, result.Fatal...)
	if result.ChecksRun == 0 && len(result.Quarantined) == 0 {
		v.Fatal = append(v.Fatal, fmt.Sprintf(
			"%s: the launch executed no check at all", group.Path))
	}
	name := filepath.Base(group.Path)
	index := slices.IndexFunc(result.Checks, func(outcome CheckOutcome) bool {
		return outcome.Name == name
	})
	record := CheckVerdict{
		Name: name, File: group.Path,
		Seed: group.Kind.Seed(), Agent: group.Kind.Agent(), Launch: group.Kind.String()}
	if index < 0 {
		record.Missing = true
	} else {
		outcome := result.Checks[index]
		record.Assertions = outcome.Assertions
		record.Failures = outcome.Failures
		// **A check that asserted nothing is not red however it failed.**
		// Whatever went wrong came from an act, and an act that could not be
		// made against an older bundle is not the same claim as an assertion
		// that could not hold there.
		record.Red = outcome.Red() && outcome.Assertions > 0
	}
	v.Checks = append(v.Checks, record)
}

// AddRedirect records a check this run did not try to prove, and where its
// failability was established instead.
func (v *Verdict) AddRedirect(file, reason string) {
	v.Checks = append(v.Checks, CheckVerdict{
		Name:       filepath.Base(file),
		File:       file,
		Redirected: true,
		Reason:     reason,
	})
}

// Proved reports whether this run proved any check failable at all.
//
// A verdict with no checks passes Err — a branch that added none does not
// fail this target — and has proved nothing, which is a different thing and
// must be readable as one.
func (v Verdict) Proved() bool {
	for _, check := range v.Checks {
		if !check.Redirected {
			return true
		}
	}
	return false
}

// Err is the verdict: every recorded check must have gone red.
func (v Verdict) Err() error {
	if len(v.Fatal) > 0 {
		return fmt.Errorf("the run itself is unsound, so nothing it reports is evidence:\n  %s",
			joinLines(v.Fatal))
	}
	var unproved []string
	for _, check := range v.Checks {
		switch {
		case check.Redirected:
			// Not proved HERE, and not a failure of this run: the entry names
			// where it was seen to fail and a reviewer reads that.
		case check.Missing:
			unproved = append(unproved, fmt.Sprintf(
				"%s never ran, so it is not a check that went red", check.File))
		case check.Assertions == 0:
			unproved = append(unproved, fmt.Sprintf(
				"%s asserted nothing, so it cannot have been seen to fail", check.File))
		case !check.Red:
			unproved = append(unproved, fmt.Sprintf(
				"%s passed against %s, so it is not testing the work on this branch",
				check.File, ShortCommit(v.BaseCommit)))
		}
	}
	if len(unproved) == 0 {
		return nil
	}
	return fmt.Errorf("%d of %d check(s) were not proved failable:\n  %s",
		len(unproved), len(v.Checks), joinLines(unproved))
}

// WriteVerdict puts the record down, and points `latest.json` at it.
//
// Both, every time: the run directory is the dated history, and the pointer
// is what a rung reads without knowing when the run happened. A pointer that
// lagged the run it points at would certify the previous branch.
func WriteVerdict(root, stamp string, verdict Verdict) (string, error) {
	if verdict.GeneratedAt.IsZero() {
		verdict.GeneratedAt = time.Now().UTC()
	}
	// `[]` rather than `null` for a run that recorded nothing: a reader
	// iterating the checks should find an empty list, not have to know that
	// Go's nil slice encodes as a JSON null.
	if verdict.Checks == nil {
		verdict.Checks = []CheckVerdict{}
	}
	encoded, err := json.MarshalIndent(verdict, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encoding the verdict: %w", err)
	}
	encoded = append(encoded, '\n')

	dir := filepath.Join(root, stamp)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("making the verdict directory: %w", err)
	}
	path := filepath.Join(dir, "verdict.json")
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		return "", fmt.Errorf("writing the verdict: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, "latest.json"), encoded, 0o644); err != nil {
		return path, fmt.Errorf("writing the latest verdict pointer: %w", err)
	}
	return path, nil
}

// ReadLatestVerdict reads the record `latest.json` points at.
//
// **Absence is reported as absence, not as an error.** Its reader is the Cover
// rung, and *"`make e2e-new` has not run"* is one of the three things that rung
// exists to say — a reader that could not distinguish that from a broken file
// would have to guess which, and the flattering guess is the wrong one.
func ReadLatestVerdict(root string) (Verdict, bool, error) {
	path := filepath.Join(root, "latest.json")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Verdict{}, false, nil
		}
		return Verdict{}, false, fmt.Errorf("reading %s: %w", path, err)
	}
	var verdict Verdict
	if err := json.Unmarshal(data, &verdict); err != nil {
		return Verdict{}, false, fmt.Errorf("reading %s: %w", path, err)
	}
	return verdict, true, nil
}

// ShortCommit renders a commit for a message, and says so when there isn't
// one.
//
// **Exported because the command had its own copy**, which returned "" for an
// empty commit where this returns "the base build" — two answers to one
// question, differing in exactly the case a reader would most need the words.
func ShortCommit(commit string) string {
	switch {
	case commit == "":
		return "the base build"
	case len(commit) > 12:
		return commit[:12]
	default:
		return commit
	}
}
