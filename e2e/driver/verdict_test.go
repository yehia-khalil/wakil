package driver

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func redRun() Result {
	return Result{
		ChecksRun:  1,
		Assertions: 1,
		Checks: []CheckOutcome{
			{Name: "terminal-block.jsonl", Assertions: 1,
				Failures: []string{"terminal-block.jsonl step 3: the tree does not contain \"exit 0\""}},
		},
	}
}

func TestVerdictRecordsWhichChecksWentRedAndWhy(t *testing.T) {
	verdict := Verdict{BaseCommit: "abc1234", HeadCommit: "def5678"}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/terminal-block.jsonl"}, redRun())

	if len(verdict.Checks) != 1 {
		t.Fatalf("want one check recorded, got %v", verdict.Checks)
	}
	recorded := verdict.Checks[0]
	if recorded.File != "e2e/checks/seeded/terminal-block.jsonl" {
		t.Fatalf("the record must carry the path, not only the name, got %q", recorded.File)
	}
	if !recorded.Red {
		t.Fatal("the check failed against the base build, so it is red")
	}
	if !recorded.Seed {
		t.Fatal("the fixture state the check ran in is part of the record")
	}
	// **The reason is recorded, not only the verdict.** A reader of the Cover
	// rung has to be able to tell a check that failed on its own assertion
	// from one that failed because the harness could not reach the window.
	if len(recorded.Failures) != 1 || !strings.Contains(recorded.Failures[0], "exit 0") {
		t.Fatalf("want the failure text carried, got %v", recorded.Failures)
	}
	if err := verdict.Err(); err != nil {
		t.Fatalf("every check went red, so the verdict is a pass: %v", err)
	}
}

// A check the run never reported is red in neither direction, and the record
// must say so rather than leaving it out — an absent row reads as a check
// nobody wrote.
func TestVerdictRecordsACheckTheRunNeverReported(t *testing.T) {
	verdict := Verdict{}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/terminal-block.jsonl"}, redRun())
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/quarantined.jsonl"}, redRun())

	if len(verdict.Checks) != 2 {
		t.Fatalf("want both checks recorded, got %v", verdict.Checks)
	}
	missing := verdict.Checks[1]
	if missing.Red || !missing.Missing {
		t.Fatalf("want the second check recorded as never run, got %+v", missing)
	}
	if err := verdict.Err(); err == nil {
		t.Fatal("a check that never ran is not a check that went red")
	}
}

// **A verdict taken from a dirty tree does not describe the branch.** The
// Cover rung reads this record as evidence about a commit; if the tree had
// uncommitted changes when it was written, the checks that ran are not the
// checks in the commit, and only the record can say so.
func TestVerdictCarriesWhetherTheTreeWasDirty(t *testing.T) {
	verdict := Verdict{Dirty: true}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/terminal-block.jsonl"}, redRun())
	if err := verdict.Err(); err != nil {
		t.Fatalf("a dirty tree is reported, not refused: %v", err)
	}
	if !verdict.Dirty {
		t.Fatal("want the dirty flag preserved")
	}
}

// A branch that added no checks is neither a pass nor a failure of this
// target, and the record has to distinguish that from a run that proved
// something — otherwise the Cover rung reads "ok" and moves on.
func TestVerdictWithNoChecksIsNotEvidence(t *testing.T) {
	verdict := Verdict{}
	if err := verdict.Err(); err != nil {
		t.Fatalf("a branch with no new checks does not fail this target: %v", err)
	}
	if verdict.Proved() {
		t.Fatal("a run that proved no check failable has proved nothing")
	}
}

func TestWriteVerdictLeavesARunRecordAndALatestPointer(t *testing.T) {
	root := t.TempDir()
	verdict := Verdict{BaseCommit: "abc1234", HeadCommit: "def5678"}
	verdict.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/terminal-block.jsonl"}, redRun())

	path, err := WriteVerdict(root, "20260923-120000", verdict)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if path != filepath.Join(root, "20260923-120000", "verdict.json") {
		t.Fatalf("got %q", path)
	}
	// **`latest.json` is what the Cover rung reads**, so it must be there and
	// must be the same verdict — a pointer that lags the run it points at
	// would certify the previous branch.
	for _, name := range []string{path, filepath.Join(root, "latest.json")} {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var read Verdict
		if err := json.Unmarshal(data, &read); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if read.BaseCommit != "abc1234" || len(read.Checks) != 1 || !read.Checks[0].Red {
			t.Fatalf("%s: round-trip lost the verdict: %+v", name, read)
		}
	}
}

// The Cover rung reads the failability record without being told where it is,
// which is what `latest.json` is for.
func TestTheLatestVerdictIsReadFromItsFixedPointer(t *testing.T) {
	root := t.TempDir()
	written := Verdict{BaseCommit: "1d521b0bbbb", HeadCommit: "63c7793aaaa"}
	written.Add(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/terminal-block.jsonl"}, redRun())
	if _, err := WriteVerdict(root, "20260924-060000", written); err != nil {
		t.Fatalf("writing the verdict: %v", err)
	}

	read, found, err := ReadLatestVerdict(root)
	if err != nil {
		t.Fatalf("reading the latest verdict: %v", err)
	}
	if !found {
		t.Fatal("a verdict was written, so one is found")
	}
	if read.BaseCommit != "1d521b0bbbb" || len(read.Checks) != 1 {
		t.Fatalf("want the record that was written, got %+v", read)
	}
}

// **A verdict that was never written is a state, not a fault.** The reader is
// the Cover rung, and "`make e2e-new` has not run" is one of the things it has
// to be able to say — which it cannot do if this returns an error that reads
// like a broken file.
func TestNoVerdictAtAllIsReportedAsAbsenceRatherThanAsAFault(t *testing.T) {
	_, found, err := ReadLatestVerdict(t.TempDir())
	if err != nil {
		t.Fatalf("no verdict yet is a state: %v", err)
	}
	if found {
		t.Fatal("nothing was written, so nothing is found")
	}
}

func TestAnUnreadableVerdictIsAFault(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "latest.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatalf("writing the broken pointer: %v", err)
	}
	if _, _, err := ReadLatestVerdict(root); err == nil {
		t.Fatal("a record that cannot be read must not pass as a run that did not happen")
	}
}
