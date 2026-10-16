package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func greenRun() Result {
	return Result{
		ChecksRun:  1,
		Assertions: 9,
		Checks: []CheckOutcome{
			{Name: "2c-iii-1-bundle-path.jsonl", Assertions: 9},
		},
		Tools: []Tool{{Name: "pane_open"}},
	}
}

func TestRunRecordCarriesWhatOneLaunchDid(t *testing.T) {
	root := t.TempDir()
	record := RunRecordOf(Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/2c-iii-1-bundle-path.jsonl"},
		greenRun(), nil)
	record.HeadCommit = "abc1234def"
	record.Bundle = "app/Wakil.app"

	path, err := WriteRunRecord(root, record)
	if err != nil {
		t.Fatalf("writing the run record: %v", err)
	}
	if filepath.Dir(path) != filepath.Join(root, RunRecordDir) {
		t.Fatalf("the record belongs under %s, got %s", RunRecordDir, path)
	}

	read, err := ReadRunRecords(root)
	if err != nil {
		t.Fatalf("reading the run records: %v", err)
	}
	if len(read) != 1 {
		t.Fatalf("want one record, got %d", len(read))
	}
	got := read[0]
	if got.File != "e2e/checks/seeded/2c-iii-1-bundle-path.jsonl" {
		t.Fatalf("the record must carry the path, not only the name, got %q", got.File)
	}
	if !got.Seed {
		t.Fatal("the fixture state the launch ran in is part of the record")
	}
	if got.Assertions != 9 || got.ChecksRun != 1 {
		t.Fatalf("want the counts carried, got %d check(s) and %d assertion(s)",
			got.ChecksRun, got.Assertions)
	}
	if got.Exit != 0 {
		t.Fatalf("a run with no failure exits 0, got %d", got.Exit)
	}
	if !got.Green() {
		t.Fatal("a run that ran a check, asserted something and failed nothing is green")
	}
}

// The record exists so a rung can read what the launch did without being told
// where to look, and the reason it is not the verdict's job is that a red run
// leaves one too. A failure's own words travel with it — .context/ is
// gitignored, so a machine section that only cited a path would cite nothing a
// reader of the repository can open.
func TestRunRecordCarriesTheFailureAndItsExitStatus(t *testing.T) {
	root := t.TempDir()
	red := Result{
		ChecksRun:  1,
		Assertions: 4,
		Failures:   []string{"landing.jsonl step 2: the tree does not contain \"e2e-fixture\""},
		Checks: []CheckOutcome{{Name: "landing.jsonl", Assertions: 4,
			Failures: []string{"landing.jsonl step 2: the tree does not contain \"e2e-fixture\""}}},
	}
	record := RunRecordOf(Group{Path: "e2e/checks/seeded/landing.jsonl"}, red, red.Err())
	if _, err := WriteRunRecord(root, record); err != nil {
		t.Fatalf("writing the run record: %v", err)
	}

	read, err := ReadRunRecords(root)
	if err != nil {
		t.Fatalf("reading the run records: %v", err)
	}
	got := read[0]
	if got.Exit != 1 {
		t.Fatalf("a run that failed a check exits 1, got %d", got.Exit)
	}
	if got.Green() {
		t.Fatal("a run carrying a failure is not green")
	}
	if len(got.Checks) != 1 || len(got.Checks[0].Failures) != 1 {
		t.Fatalf("the failure travels with the record, got %+v", got.Checks)
	}
	if !strings.Contains(got.Note, "e2e-fixture") {
		t.Fatalf("the run's own verdict is recorded in words, got %q", got.Note)
	}
}

// A launch that executed no check exits 0 from the checks' point of view and
// proved nothing, which is the silence this whole harness refuses. The record
// must not read as a green walk.
func TestRunRecordRefusesToCallAnEmptyLaunchGreen(t *testing.T) {
	record := RunRecordOf(Group{Path: "e2e/checks/seeded/empty.jsonl"}, Result{}, Result{}.Err())
	if record.Green() {
		t.Fatal("a launch that ran no check proved nothing, so it is not green")
	}
	if record.Exit == 0 {
		t.Fatal("a launch that proved nothing must not record a passing exit status")
	}
}

// One launch per check file is the rule `make e2e` is built on, so the record
// is keyed by the file: a second run of the same checks replaces its
// predecessor rather than accumulating a history nobody prunes.
func TestASecondRunOfTheSameFileReplacesTheFirst(t *testing.T) {
	root := t.TempDir()
	group := Group{Kind: SeededLaunch, Path: "e2e/checks/seeded/landing.jsonl"}
	red := Result{ChecksRun: 1, Assertions: 1, Failures: []string{"landing.jsonl step 1: no"},
		Checks: []CheckOutcome{{Name: "landing.jsonl", Assertions: 1,
			Failures: []string{"landing.jsonl step 1: no"}}}}
	if _, err := WriteRunRecord(root, RunRecordOf(group, red, red.Err())); err != nil {
		t.Fatalf("writing the first record: %v", err)
	}
	green := Result{ChecksRun: 1, Assertions: 1,
		Checks: []CheckOutcome{{Name: "landing.jsonl", Assertions: 1}}}
	if _, err := WriteRunRecord(root, RunRecordOf(group, green, nil)); err != nil {
		t.Fatalf("writing the second record: %v", err)
	}

	read, err := ReadRunRecords(root)
	if err != nil {
		t.Fatalf("reading the run records: %v", err)
	}
	if len(read) != 1 {
		t.Fatalf("want one record for one check file, got %d", len(read))
	}
	if !read[0].Green() {
		t.Fatal("the later run is the one that stands")
	}
}

func TestRunRecordsAreReadInAStableOrder(t *testing.T) {
	root := t.TempDir()
	for _, path := range []string{
		"e2e/checks/seeded/vocabulary.jsonl",
		"e2e/checks/unseeded/org-plane.jsonl",
		"e2e/checks/seeded/landing.jsonl",
	} {
		result := Result{ChecksRun: 1, Assertions: 1,
			Checks: []CheckOutcome{{Name: filepath.Base(path), Assertions: 1}}}
		if _, err := WriteRunRecord(root, RunRecordOf(Group{Path: path}, result, nil)); err != nil {
			t.Fatalf("writing %s: %v", path, err)
		}
	}
	read, err := ReadRunRecords(root)
	if err != nil {
		t.Fatalf("reading the run records: %v", err)
	}
	var files []string
	for _, record := range read {
		files = append(files, record.File)
	}
	want := []string{
		"e2e/checks/seeded/landing.jsonl",
		"e2e/checks/seeded/vocabulary.jsonl",
		"e2e/checks/unseeded/org-plane.jsonl",
	}
	if strings.Join(files, ",") != strings.Join(want, ",") {
		t.Fatalf("want the records in path order %v, got %v", want, files)
	}
}

// A record describing another commit is the denominator's failure mode: it
// reports a green walk of a build that is not the one being certified.
func TestARecordFromAnotherCommitIsRefused(t *testing.T) {
	record := RunRecordOf(Group{Path: "e2e/checks/seeded/landing.jsonl"}, greenRun(), nil)
	record.HeadCommit = "0123456789abcdef"
	if err := record.Err("fedcba9876543210"); err == nil {
		t.Fatal("a record observed against another commit certifies another build")
	} else if !strings.Contains(err.Error(), "make e2e") {
		t.Fatalf("the refusal must name the target that fixes it, got %q", err)
	}
	if err := record.Err("0123456789abcdef"); err != nil {
		t.Fatalf("the record describes this commit: %v", err)
	}
}

func TestReadingRunRecordsFromANonexistentRootIsEmptyRatherThanAnError(t *testing.T) {
	read, err := ReadRunRecords(filepath.Join(t.TempDir(), "never-run"))
	if err != nil {
		t.Fatalf("a root with no runs in it is a state, not a fault: %v", err)
	}
	if len(read) != 0 {
		t.Fatalf("want no records, got %d", len(read))
	}
}

func TestAnUnreadableRunRecordIsAFaultRatherThanASilentOmission(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, RunRecordDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("making the run directory: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "landing.jsonl.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatalf("writing the broken record: %v", err)
	}
	if _, err := ReadRunRecords(root); err == nil {
		t.Fatal("a record that cannot be read must not pass as a run that did not happen")
	}
}

// One launch may be given several check files, and the record is per file.
// **A file's record must carry that file's verdict**, not the launch's total:
// a record saying nine assertions ran when four of them belonged to another
// check is a number nobody can check.
func TestAResultNarrowsToOneCheckWithoutLosingTheLaunchsOwnFacts(t *testing.T) {
	launch := Result{
		ChecksRun:  2,
		Assertions: 5,
		Failures:   []string{"landing.jsonl step 2: no"},
		Checks: []CheckOutcome{
			{Name: "landing.jsonl", Assertions: 4, Failures: []string{"landing.jsonl step 2: no"}},
			{Name: "vocabulary.jsonl", Assertions: 1},
		},
		Quarantined: []string{"flaky.jsonl: quarantined, and it passed this time"},
		Evidence:    ".context/e2e/20260924-055545",
	}

	narrowed := launch.For("vocabulary.jsonl")
	if narrowed.ChecksRun != 1 || narrowed.Assertions != 1 {
		t.Fatalf("want this check's own counts, got %d check(s) and %d assertion(s)",
			narrowed.ChecksRun, narrowed.Assertions)
	}
	if err := narrowed.Err(); err != nil {
		t.Fatalf("this check failed nothing, so its own verdict is a pass: %v", err)
	}
	if narrowed.Evidence != launch.Evidence || len(narrowed.Quarantined) != 1 {
		t.Fatal("the launch's evidence directory and quarantine are facts about every check in it")
	}

	failed := launch.For("landing.jsonl")
	if err := failed.Err(); err == nil {
		t.Fatal("the check that failed keeps its failure")
	}
}

// A check the launch never reported is not a pass. It is the absent row
// Verdict.Add already refuses to leave out, in the other record.
func TestNarrowingToACheckTheLaunchNeverRanIsNotAPass(t *testing.T) {
	launch := Result{ChecksRun: 1, Assertions: 1,
		Checks: []CheckOutcome{{Name: "landing.jsonl", Assertions: 1}}}
	if err := launch.For("never-ran.jsonl").Err(); err == nil {
		t.Fatal("a check that did not run proved nothing, so it cannot read as green")
	}
}
