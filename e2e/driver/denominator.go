package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// DenominatorFile is what a run leaves the action denominator in, under the
// evidence root. `latest.json` is the verdict's pointer and this is the
// denominator's; both are fixed names for the same reason — a record whose
// location depends on the run is a record nobody reads.
const DenominatorFile = "actions.json"

// Denominator is the action half of coverage, as one run observed it.
//
// **Why this is a file and not another launch.** The actions a build exposes
// are only knowable from a live window — `ActionRegistry` is the only
// enumeration, and it lives inside the process — so the gate either launches
// an instance of its own or reads what the run it follows already saw.
// `Session.Run` asks `tools/list` on every launch before the first check, so
// the list is already in hand; writing it down makes the gate a pure
// computation over files, runnable without a GUI, in the same second the
// checks finish.
//
// **What that costs, and what refuses to pay it.** A file can be stale where a
// launch cannot, and a stale denominator fails in the flattering direction: it
// describes an older build, which does not have the action this branch just
// added, so the gate would find nothing new and pass by being blind. `Err`
// refuses exactly that — the record carries the commit it was observed against
// and is only good for that commit.
type Denominator struct {
	ObservedAt time.Time `json:"observedAt"`
	// HeadCommit is what the repository was on when the window that answered
	// was launched.
	HeadCommit string `json:"headCommit"`
	// Dirty reports that the tree carried uncommitted changes, so the bundle
	// this was read from is not the commit. Recorded rather than refused, for
	// the reason Verdict.Dirty is: an operator iterating on a check runs this
	// constantly, and a record that says "not the commit" is more use than no
	// record at all.
	Dirty bool `json:"dirty,omitempty"`
	// Bundle is the app the window was launched from, for a reader trying to
	// work out which build answered.
	Bundle string `json:"bundle,omitempty"`
	Tools  []Tool `json:"tools"`
}

// WriteDenominator puts the record down beside the run's evidence.
func WriteDenominator(root string, denominator Denominator) (string, error) {
	if len(denominator.Tools) == 0 {
		return "", fmt.Errorf(
			"refusing to record an empty action denominator: every coverage claim measured " +
				"against it would be vacuous, and a file saying so outlives the run that wrote it")
	}
	if denominator.ObservedAt.IsZero() {
		denominator.ObservedAt = time.Now().UTC()
	}
	encoded, err := json.MarshalIndent(denominator, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encoding the action denominator: %w", err)
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", fmt.Errorf("making %s: %w", root, err)
	}
	path := filepath.Join(root, DenominatorFile)
	if err := os.WriteFile(path, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("writing the action denominator: %w", err)
	}
	return path, nil
}

// ReadDenominator reads the record a run left.
//
// **A missing record is refused, and the refusal says how to make one.** The
// alternative is a gate that reports an empty denominator as full coverage of
// nothing, which is the silence this harness exists to refuse — and the reader
// of that message is somebody who has just run the gate on its own.
func ReadDenominator(root string) (Denominator, error) {
	path := filepath.Join(root, DenominatorFile)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Denominator{}, fmt.Errorf(
				"no action denominator at %s: the actions a build exposes are only knowable "+
					"from a live window, so run `make e2e` (which records them) before asking "+
					"what they cover", path)
		}
		return Denominator{}, fmt.Errorf("reading %s: %w", path, err)
	}
	var denominator Denominator
	if err := json.Unmarshal(data, &denominator); err != nil {
		return Denominator{}, fmt.Errorf("reading %s: %w", path, err)
	}
	if len(denominator.Tools) == 0 {
		return Denominator{}, fmt.Errorf(
			"%s records no actions at all, so every coverage claim measured against it "+
				"would be vacuous", path)
	}
	return denominator, nil
}

// Err reports whether this record describes the commit now checked out.
func (d Denominator) Err(head string) error {
	if d.HeadCommit == head {
		return nil
	}
	return fmt.Errorf(
		"the action denominator was observed against %s and this tree is on %s — measured "+
			"against the wrong build the gate cannot see an action this branch added, and "+
			"would pass by being blind. Run `make e2e` to record the current one",
		ShortCommit(d.HeadCommit), ShortCommit(head))
}

// StaleNote says the same thing as Err for a reader who is allowed to carry
// on: the backlog, which is a list of work rather than a verdict, and is worth
// reading a commit out of date as long as it says which commit it describes.
func (d Denominator) StaleNote(head string) string {
	return fmt.Sprintf(
		"these actions were observed against %s and this tree is on %s, so this list is "+
			"that build's. Run `make e2e` for the current one",
		ShortCommit(d.HeadCommit), ShortCommit(head))
}

// Actions lists the tools this record holds, so callers do not reach into the
// field to build a surface.
func (d Denominator) Actions() []Tool { return d.Tools }
