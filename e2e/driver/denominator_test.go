package driver_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func TestTheDenominatorSurvivesARoundTrip(t *testing.T) {
	root := t.TempDir()
	written := driver.Denominator{
		HeadCommit: "abc123",
		Tools: []driver.Tool{
			{Name: "term_open"},
			{Name: "read_pane", ReadOnly: true},
		},
	}
	path, err := driver.WriteDenominator(root, written)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != root {
		t.Errorf("the record landed at %s, outside %s", path, root)
	}
	read, err := driver.ReadDenominator(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(read.Tools) != 2 || read.Tools[0].Name != "term_open" || !read.Tools[1].ReadOnly {
		t.Errorf("the tools did not survive: %+v", read.Tools)
	}
	if read.ObservedAt.IsZero() {
		t.Error("the record does not say when it was observed, so nothing can tell it is stale")
	}
}

// **A gate with no denominator is not a gate that passes.** The action half of
// coverage is only knowable from a live window; if no run has left one, the
// honest answer is that this cannot be judged yet, and the reader is sent to
// the target that produces it.
func TestAMissingDenominatorIsRefusedRatherThanEmpty(t *testing.T) {
	_, err := driver.ReadDenominator(t.TempDir())
	if err == nil {
		t.Fatal("a missing record was read as an empty denominator")
	}
	if !strings.Contains(err.Error(), "make e2e") {
		t.Errorf("the refusal does not say how to produce one: %v", err)
	}
}

// **A denominator from another commit is refused.** It is a list of what the
// app could do at the commit it was observed against; measured against a
// branch that has since added an action, it says the new action does not
// exist — so the gate would pass by being blind, which is the one way a gate
// must never pass.
func TestADenominatorFromAnotherCommitIsRefused(t *testing.T) {
	root := t.TempDir()
	if _, err := driver.WriteDenominator(root, driver.Denominator{
		HeadCommit: "0000000000000000000000000000000000000000",
		Tools:      []driver.Tool{{Name: "term_open"}},
	}); err != nil {
		t.Fatal(err)
	}
	read, err := driver.ReadDenominator(root)
	if err != nil {
		t.Fatal(err)
	}
	err = read.Err("1111111111111111111111111111111111111111")
	if err == nil {
		t.Fatal("a denominator observed against another commit was accepted")
	}
	if !strings.Contains(err.Error(), "000000000000") ||
		!strings.Contains(err.Error(), "111111111111") {
		t.Errorf("the refusal names neither commit: %v", err)
	}
	if read.Err("0000000000000000000000000000000000000000") != nil {
		t.Error("a denominator from this very commit was refused")
	}
}

// A run against a dirty tree is recorded as such rather than refused — the
// operator iterating on a check runs this constantly — but the record has to
// carry the fact, because the checks that ran are then not the checks in the
// commit.
func TestADirtyRunIsRecordedRatherThanRefused(t *testing.T) {
	root := t.TempDir()
	if _, err := driver.WriteDenominator(root, driver.Denominator{
		HeadCommit: "abc", Dirty: true, Tools: []driver.Tool{{Name: "term_open"}},
	}); err != nil {
		t.Fatal(err)
	}
	read, err := driver.ReadDenominator(root)
	if err != nil {
		t.Fatal(err)
	}
	if !read.Dirty {
		t.Error("the record does not carry that the tree was dirty")
	}
	if err := read.Err("abc"); err != nil {
		t.Errorf("a dirty run was refused: %v", err)
	}
}

// An empty tool list reaching the record would make every coverage claim
// measured against it vacuous — the same refusal `MCP.Tools` makes one level
// up, repeated here because this file outlives the run that wrote it.
func TestADenominatorWithNoToolsIsRefused(t *testing.T) {
	root := t.TempDir()
	if _, err := driver.WriteDenominator(root, driver.Denominator{HeadCommit: "abc"}); err == nil {
		t.Fatal("a record with no tools was written")
	}
	if err := os.WriteFile(filepath.Join(root, "actions.json"),
		[]byte(`{"observedAt":"2026-09-24T00:00:00Z","headCommit":"abc","tools":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := driver.ReadDenominator(root); err == nil {
		t.Fatal("a record with no tools was read as a denominator")
	}
}

func TestTheDenominatorNamesItsWriteTimeWhenTheCallerDoesNot(t *testing.T) {
	root := t.TempDir()
	before := time.Now().UTC().Add(-time.Second)
	if _, err := driver.WriteDenominator(root, driver.Denominator{
		HeadCommit: "abc", Tools: []driver.Tool{{Name: "term_open"}},
	}); err != nil {
		t.Fatal(err)
	}
	read, err := driver.ReadDenominator(root)
	if err != nil {
		t.Fatal(err)
	}
	if read.ObservedAt.Before(before) {
		t.Errorf("observedAt is %s, which is not when this ran", read.ObservedAt)
	}
}
