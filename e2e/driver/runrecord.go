package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// RunRecordDir is where a launch leaves what it did, under the evidence root.
//
// **A fixed, known path**, for the reason `DenominatorFile` and
// `DefaultVerdictRoot` are: the Cover rung reads this without being told where
// to look, and a record whose location depends on the run is a record nobody
// reads.
const RunRecordDir = "runs"

// CheckRun is what one check did inside a launch.
//
// It is `CheckOutcome` written down. The two are kept apart on purpose:
// `CheckOutcome` is the runner's live value and changes when the runner does,
// while this is a file format something else reads back — including a file
// written by a build that has since been replaced.
type CheckRun struct {
	Name       string   `json:"name"`
	Assertions int      `json:"assertions"`
	Failures   []string `json:"failures,omitempty"`
	// Evidence names what the check's evidence directory holds — the
	// screenshot, the tree, the pane snapshot — and EvidenceGaps what could
	// not be gathered and why. **Names rather than the artefacts themselves**:
	// they are large and binary, and the directory is gitignored, so what a
	// document can honestly carry is that they exist and where.
	Evidence     []string `json:"evidence,omitempty"`
	EvidenceGaps []string `json:"evidenceGaps,omitempty"`
}

// RunRecord is what one launch of `make e2e` did, written down.
//
// **Why a run needs a record at all, when a red run already leaves evidence.**
// The evidence directory holds what a FAILING check saw. The machine half of
// an acceptance runbook is a claim about the run that PASSED — which checks
// ran, against which build, asserting how much, exiting how — and nothing was
// keeping that. The alternative was an agent typing the numbers into the
// runbook out of a terminal it had just read, which is the hand-kept second
// answer this repository keeps deleting.
//
// **It carries the failure text and not only a path.** `.context/` is
// gitignored, so a section that cited only a directory would cite nothing a
// reader of the repository can open — the lesson `agent-e2e-retrodiction.md`
// was written under, in its own words: put the run in the document.
type RunRecord struct {
	RanAt time.Time `json:"ranAt"`
	// File is the check file this launch ran. One launch per check file is
	// `make e2e`'s rule, so this is also the record's identity.
	File string `json:"file"`
	// Seed is the fixture state the launch ran in.
	Seed bool `json:"seed"`
	// HeadCommit is what the repository was on when the launch happened, and
	// Dirty says the tree carried uncommitted changes — so a reader can tell a
	// walk of this commit from a walk of something near it.
	HeadCommit string `json:"headCommit,omitempty"`
	Dirty      bool   `json:"dirty,omitempty"`
	Bundle     string `json:"bundle,omitempty"`
	// Exit is the status the runner would exit with: 0 only when the run may
	// be called a pass, which is Result.Err's question and not a count of
	// failures.
	Exit       int        `json:"exit"`
	ChecksRun  int        `json:"checksRun"`
	Assertions int        `json:"assertions"`
	Checks     []CheckRun `json:"checks,omitempty"`
	// Quarantined and Fatal travel for the same reason they are printed on
	// every run: a quarantine nobody is reminded of is a check that has been
	// deleted without anyone deciding to.
	Quarantined []string `json:"quarantined,omitempty"`
	Fatal       []string `json:"fatal,omitempty"`
	// Note is the run's own verdict in words — the error Result.Err returned,
	// or empty when it returned none.
	Note string `json:"note,omitempty"`
	// Evidence is the directory a failing check left its screenshot, tree and
	// pane snapshot in. Empty when nothing failed.
	Evidence string `json:"evidence,omitempty"`
}

// RunRecordOf turns one launch into its record.
//
// runErr is the run's verdict — `Result.Err`, or a fault in the run itself.
// **It is taken as an argument rather than recomputed here** so that a caller
// which failed before the checks ran, or for a reason the result cannot see,
// records the reason it actually exited with.
func RunRecordOf(group Group, result Result, runErr error) RunRecord {
	record := RunRecord{
		RanAt:       time.Now().UTC(),
		File:        group.Path,
		Seed:        group.Kind.Seed(),
		ChecksRun:   result.ChecksRun,
		Assertions:  result.Assertions,
		Quarantined: result.Quarantined,
		Fatal:       result.Fatal,
		Evidence:    result.Evidence,
	}
	for _, outcome := range result.Checks {
		record.Checks = append(record.Checks, CheckRun{
			Name:         outcome.Name,
			Assertions:   outcome.Assertions,
			Failures:     outcome.Failures,
			Evidence:     outcome.Evidence,
			EvidenceGaps: outcome.EvidenceGaps,
		})
	}
	if runErr == nil {
		runErr = result.Err()
	}
	if runErr != nil {
		record.Exit = 1
		record.Note = runErr.Error()
	}
	return record
}

// Green reports whether this launch may be read as a walk that proved
// something.
//
// **Exit 0 is the whole of it, and that is deliberate.** `Result.Err` already
// refuses a launch that ran no check and one that asserted nothing, which is
// the silence — a check that resolved a stale index, found nothing and
// asserted nothing — this harness exists to catch. Re-deriving the rule here
// would be a second answer to it.
func (r RunRecord) Green() bool { return r.Exit == 0 }

// Err reports whether this record describes the commit now checked out.
//
// It is `Denominator.Err`'s rule applied to the run: a machine section built
// from a record of another build says a walk happened that did not happen to
// this one, and it fails in the flattering direction — the checks it reports
// green never saw the code being certified.
func (r RunRecord) Err(head string) error {
	if r.HeadCommit == head {
		return nil
	}
	return fmt.Errorf(
		"%s was run against %s and this tree is on %s — a machine walk recorded from "+
			"another build certifies another build. Run `make e2e` on this one",
		r.File, ShortCommit(r.HeadCommit), ShortCommit(head))
}

// WriteRunRecord puts one launch's record down, keyed by the check file it
// ran.
//
// **Keyed by the file, so the latest run of it stands.** One launch per check
// file is `make e2e`'s own rule (a shared instance couples checks through its
// state, invisibly), which makes the file the natural identity — and it keeps
// this directory a picture of the current corpus rather than a history nobody
// prunes.
func WriteRunRecord(root string, record RunRecord) (string, error) {
	if record.File == "" {
		return "", fmt.Errorf(
			"refusing to record a run that names no check file: the record is keyed by the " +
				"file it ran, and one without it can neither be found nor replaced")
	}
	if record.RanAt.IsZero() {
		record.RanAt = time.Now().UTC()
	}
	encoded, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encoding the run record: %w", err)
	}
	dir := filepath.Join(root, RunRecordDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("making %s: %w", dir, err)
	}
	path := filepath.Join(dir, runRecordName(record.File))
	if err := os.WriteFile(path, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("writing the run record: %w", err)
	}
	return path, nil
}

// ReadRunRecords reads every launch record under the evidence root, in path
// order.
//
// **A root with no runs in it is not an error.** The caller asking is the one
// that renders the machine section, and "nothing has been run" is an answer it
// must be able to print — the refusal belongs there, where it can say which
// checks were never walked, rather than here as a missing directory.
//
// **A record that cannot be read is.** It is a launch that happened and whose
// verdict is now unknown, and treating it as a run that did not happen is the
// silent omission this harness refuses everywhere else.
func ReadRunRecords(root string) ([]RunRecord, error) {
	dir := filepath.Join(root, RunRecordDir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading %s: %w", dir, err)
	}
	var records []RunRecord
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", path, err)
		}
		var record RunRecord
		if err := json.Unmarshal(data, &record); err != nil {
			return nil, fmt.Errorf("reading %s: %w", path, err)
		}
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool { return records[i].File < records[j].File })
	return records, nil
}

// runRecordName is the file a check file's record is kept in.
//
// The separators are flattened rather than nested so the directory can be
// listed at a glance, and the whole path is kept rather than only the base
// name because the two fixture states hold files of the same name in
// different directories.
func runRecordName(file string) string {
	return strings.ReplaceAll(strings.TrimPrefix(file, "./"), string(filepath.Separator), "_") + ".json"
}
