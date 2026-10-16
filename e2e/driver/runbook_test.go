package driver

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func walkedRecord(file string, green bool) RunRecord {
	record := RunRecord{
		RanAt:      time.Date(2026, 9, 24, 5, 55, 0, 0, time.UTC),
		File:       file,
		HeadCommit: "63c7793aaaa",
		ChecksRun:  1,
		Assertions: 4,
		Checks:     []CheckRun{{Name: filepath.Base(file), Assertions: 4}},
	}
	if !green {
		record.Exit = 1
		record.Note = "1 failure(s), across 4 assertion(s)"
		record.Checks[0].Failures = []string{
			filepath.Base(file) + " step 2: the tree does not contain \"e2e-fixture\""}
		record.Evidence = ".context/e2e/20260924-055500"
	}
	return record
}

// coveredSurface is a gate that passes: one action, dispatched by the checks,
// and nothing new on the branch.
func coveredSurface() CoverageReport {
	return Judge(Surface{}, Surface{}, CoverageOf(nil), nil)
}

func provenWalk() MachineWalk {
	corpus := []string{"e2e/checks/seeded/landing.jsonl", "e2e/checks/unseeded/org-plane.jsonl"}
	covered := coveredSurface()
	return MachineWalk{
		GeneratedAt: time.Date(2026, 9, 24, 6, 0, 0, 0, time.UTC),
		HeadCommit:  "63c7793aaaa",
		Corpus:      corpus,
		Coverage:    &covered,
		Runs: []RunRecord{
			walkedRecord(corpus[0], true),
			walkedRecord(corpus[1], true),
		},
		Verdict: &Verdict{
			BaseCommit: "1d521b0bbbb",
			HeadCommit: "63c7793aaaa",
			Checks: []CheckVerdict{
				{Name: "landing.jsonl", File: corpus[0], Red: true, Assertions: 4},
				{Name: "org-plane.jsonl", File: corpus[1], Red: true, Assertions: 4},
			},
		},
	}
}

func TestAProvenWalkRendersTheThreeConditionsOfTheCoverRung(t *testing.T) {
	walk := provenWalk()
	if err := walk.Err(); err != nil {
		t.Fatalf("every check ran green and was proved failable: %v", err)
	}
	section := walk.Markdown()

	for _, want := range []string{
		"make e2e",
		"make e2e-new",
		"63c7793", // the build that was walked
		"1d521b0", // the base it was proved red against
		"landing.jsonl",
		"org-plane.jsonl",
	} {
		if !strings.Contains(section, want) {
			t.Fatalf("the section must name %q:\n%s", want, section)
		}
	}
	// **The section says it is generated.** A reader who edits it would
	// otherwise lose the edit on the next run without anything having warned
	// them.
	if !strings.Contains(section, MachineWalkOpen) || !strings.Contains(section, MachineWalkClose) {
		t.Fatalf("the section carries its own markers:\n%s", section)
	}
}

// A check file with no record is the state this whole harness refuses to let
// pass quietly: it reads as a check nobody wrote rather than as one nobody ran.
func TestACheckThatWasNeverRunIsNamedRatherThanOmitted(t *testing.T) {
	walk := provenWalk()
	walk.Corpus = append(walk.Corpus, "e2e/checks/seeded/vocabulary.jsonl")

	if err := walk.Err(); err == nil {
		t.Fatal("a check the walk never ran means `make e2e` is not green over the corpus")
	}
	section := walk.Markdown()
	if !strings.Contains(section, "vocabulary.jsonl") {
		t.Fatalf("the unrun check is named:\n%s", section)
	}
	if !strings.Contains(section, "never run") {
		t.Fatalf("and it is named as never run:\n%s", section)
	}
}

// A red check reaches the section with its own words, because .context/ is
// gitignored and a path alone would cite nothing a reader can open.
func TestARedCheckCarriesItsFailureIntoTheSection(t *testing.T) {
	walk := provenWalk()
	walk.Runs[0] = walkedRecord(walk.Corpus[0], false)

	if err := walk.Err(); err == nil {
		t.Fatal("a red check means the Cover rung is not turned")
	}
	section := walk.Markdown()
	if !strings.Contains(section, "the tree does not contain") {
		t.Fatalf("the failure's own words travel into the document:\n%s", section)
	}
	if !strings.Contains(section, ".context/e2e/20260924-055500") {
		t.Fatalf("and the evidence directory is cited as provenance:\n%s", section)
	}
}

// A record from another commit is a green walk of another build. It fails the
// same way the coverage gate's stale denominator does, and for the same reason.
func TestAWalkRecordedAgainstAnotherCommitIsRefused(t *testing.T) {
	walk := provenWalk()
	walk.Runs[0].HeadCommit = "0000000dead"

	err := walk.Err()
	if err == nil {
		t.Fatal("a record from another build must not certify this one")
	}
	if !strings.Contains(err.Error(), "make e2e") {
		t.Fatalf("the refusal names the target that fixes it, got %q", err)
	}
}

// `make e2e-new` never having run is not the same as its having passed, and a
// section that simply omitted the row would read as the second.
func TestAWalkWithNoFailabilityRecordSaysSoRatherThanStayingSilent(t *testing.T) {
	walk := provenWalk()
	walk.Verdict = nil

	if err := walk.Err(); err == nil {
		t.Fatal("a check that has never been seen to fail is not evidence")
	}
	section := walk.Markdown()
	if !strings.Contains(section, "make e2e-new") {
		t.Fatalf("the section still names the target that is missing:\n%s", section)
	}
}

// A check the failability run redirected was proved somewhere else, and the
// section reports where rather than treating it as unproved.
func TestABackfilledCheckIsReportedWithWhereItWasProved(t *testing.T) {
	walk := provenWalk()
	walk.Verdict.Checks[0] = CheckVerdict{
		Name: "landing.jsonl", File: walk.Corpus[0], Redirected: true,
		Reason: "proved by e2e/retrodiction/1-profile-never-sourced.patch",
	}

	if err := walk.Err(); err != nil {
		t.Fatalf("a redirected check is proved, elsewhere: %v", err)
	}
	if !strings.Contains(walk.Markdown(), "1-profile-never-sourced") {
		t.Fatalf("the section says where it was proved:\n%s", walk.Markdown())
	}
}

// The coverage gate's verdict is the third of the Cover rung's conditions, and
// what no check can reach is the machine-known half of the residue.
func TestTheSectionCarriesTheCoverageVerdictAndTheExcusedSurface(t *testing.T) {
	walk := provenWalk()
	report := Judge(
		Surface{Actions: []Tool{{Name: "pane_open"}}},
		Surface{},
		CoverageOf(nil),
		map[string]string{"pane_open": "the action ends the run that would assert it"},
	)
	walk.Coverage = &report

	section := walk.Markdown()
	if !strings.Contains(section, "pane_open") {
		t.Fatalf("the excused surface is named:\n%s", section)
	}
	if !strings.Contains(section, "ends the run that would assert it") {
		t.Fatalf("with the reason a reviewer reads:\n%s", section)
	}
}

func TestSplicingReplacesOnlyWhatIsBetweenTheMarkers(t *testing.T) {
	document := "# Runbook\n\nprose before\n\n" +
		MachineWalkOpen + "\nstale\n" + MachineWalkClose +
		"\n\n## 2. The human residue\n\nprose after\n"

	spliced, err := SpliceMachineWalk(document, MachineWalkOpen+"\nfresh\n"+MachineWalkClose)
	if err != nil {
		t.Fatalf("splicing: %v", err)
	}
	if strings.Contains(spliced, "stale") {
		t.Fatalf("the old section is gone:\n%s", spliced)
	}
	for _, want := range []string{"prose before", "fresh", "## 2. The human residue", "prose after"} {
		if !strings.Contains(spliced, want) {
			t.Fatalf("the human halves are untouched, want %q:\n%s", want, spliced)
		}
	}
}

// **A document with no markers is refused rather than guessed at.** Where the
// machine section belongs in a runbook is a judgement about that runbook, and
// a generator that picked a place would be editing prose it does not
// understand.
func TestSplicingADocumentWithNoMarkersIsRefusedAndSaysWhatToAdd(t *testing.T) {
	_, err := SpliceMachineWalk("# Runbook\n\nprose\n", MachineWalkOpen+"\nfresh\n"+MachineWalkClose)
	if err == nil {
		t.Fatal("a document with nowhere to put the section must not be guessed at")
	}
	if !strings.Contains(err.Error(), MachineWalkOpen) {
		t.Fatalf("the refusal shows the marker to add, got %q", err)
	}
}

func TestSplicingADocumentWithAnUnclosedMarkerIsRefused(t *testing.T) {
	document := "# Runbook\n\n" + MachineWalkOpen + "\nstale\n\n## 2. Human\n"
	if _, err := SpliceMachineWalk(document, MachineWalkOpen+"\nfresh\n"+MachineWalkClose); err == nil {
		t.Fatal("an unclosed marker would swallow the rest of the document")
	}
}

// A record from another build must not lend this one its numbers: a row
// showing four assertions beside "another build" invites the reader to count
// them towards this walk.
func TestARowFromAnotherBuildCountsNothingTowardsThisWalk(t *testing.T) {
	walk := provenWalk()
	walk.Runs[0].HeadCommit = "0000000dead"

	section := walk.Markdown()
	var row string
	for _, line := range strings.Split(section, "\n") {
		if strings.HasPrefix(line, "| `landing.jsonl`") {
			row = line
		}
	}
	if row == "" {
		t.Fatalf("the check still gets a row:\n%s", section)
	}
	if !strings.Contains(row, "another build") {
		t.Fatalf("and the row says which build it describes, got %q", row)
	}
	if strings.Contains(row, "| 4 |") {
		t.Fatalf("but it lends this walk none of its counts, got %q", row)
	}
}

// **Coverage nobody computed is an unmet condition, never a met one.** The
// section used to skip the paragraph and print "the machine walk is green"
// over a computation that never happened — which is the ordinary state of a
// tree whose denominator is stale, and the flattering direction.
func TestAWalkWhoseCoverageCouldNotBeComputedIsNotGreen(t *testing.T) {
	walk := provenWalk()
	walk.Coverage = nil
	walk.CoverageErr = errors.New("the action denominator was observed against 445a065")

	if err := walk.Err(); err == nil {
		t.Fatal("a question nothing answered must not read as an answer")
	}
	section := walk.Markdown()
	if strings.Contains(section, "The machine walk is green") {
		t.Fatalf("and the banner must not claim it:\n%s", section)
	}
	if !strings.Contains(section, "445a065") {
		t.Fatalf("the section says why coverage is unknown:\n%s", section)
	}
}

// A verdict that names no build certifies nothing, and reading an empty field
// as a match would certify this build from a record that never named one.
func TestAFailabilityRecordThatNamesNoBuildIsRefused(t *testing.T) {
	walk := provenWalk()
	walk.Verdict.HeadCommit = ""

	if err := walk.Err(); err == nil {
		t.Fatal("a record that does not say which build it describes proves nothing about this one")
	}
}

// The verdict records the path `make e2e-new` was given; the corpus records
// the path a glob produced. Drift between the two spellings must not turn
// "never proved failable" into "not new on this branch".
func TestACheckIsRecognisedAcrossSpellingsOfItsPath(t *testing.T) {
	walk := provenWalk()
	walk.Verdict.Checks[0].File = "./e2e/checks/seeded/landing.jsonl"
	walk.Verdict.Checks[0].Red = false

	if err := walk.Err(); err == nil {
		t.Fatal("the check passed against the base, and a different spelling must not hide it")
	}
	if strings.Contains(walk.Markdown(), "not new on this branch") {
		t.Fatalf("nor read as a check the branch never touched:\n%s", walk.Markdown())
	}
}

// The ticket asks the machine section to carry evidence — exit codes,
// snapshots, screenshots. The first two travel as text; a screenshot cannot,
// because `.context/` is gitignored. **So the section says what exists and
// where**, and says what could not be gathered, which is the part a reader
// would otherwise put down to there having been nothing to see.
func TestARedCheckNamesTheEvidenceThatExistsAndWhatIsMissing(t *testing.T) {
	walk := provenWalk()
	record := walkedRecord(walk.Corpus[0], false)
	record.Checks[0].Evidence = []string{"tree.txt", "screenshot.png", "panes.json", "failure.txt"}
	record.Checks[0].EvidenceGaps = []string{"orca captured no screenshot (screenshotStatus was \"denied\")"}
	walk.Runs[0] = record

	section := walk.Markdown()
	for _, want := range []string{
		"screenshot.png",
		"panes.json",
		".context/e2e/20260924-055500",
		"gitignored",
		"screenshotStatus",
	} {
		if !strings.Contains(section, want) {
			t.Fatalf("the section must name %q:\n%s", want, section)
		}
	}
}

// **A vacuous truth must not be stated as an achievement.** A branch that
// added no check has none that were seen to fail, and a banner reading "every
// check this branch added was seen to fail against the merge-base" over that
// record claims evidence the run does not hold — which is what the paragraph
// below it already says plainly.
func TestTheGreenBannerDoesNotClaimFailabilityNothingProved(t *testing.T) {
	walk := provenWalk()
	walk.Verdict = &Verdict{BaseCommit: "1d521b0bbbb", HeadCommit: "63c7793aaaa"}

	if err := walk.Err(); err != nil {
		t.Fatalf("a branch that added no check does not fail this rung: %v", err)
	}
	section := walk.Markdown()
	if !strings.Contains(section, "The machine walk is green") {
		t.Fatalf("it is still green:\n%s", section)
	}
	if strings.Contains(section, "every check this branch added was seen to fail") {
		t.Fatalf("but it claims no proof it does not hold:\n%s", section)
	}
	if !strings.Contains(section, "added no check") {
		t.Fatalf("and it says why there was nothing to prove:\n%s", section)
	}
}

// selectedWalk is provenWalk with a third check that the selection did not
// pick and nothing ran.
func selectedWalk(selection Selection) MachineWalk {
	walk := provenWalk()
	walk.Corpus = append(walk.Corpus, "e2e/checks/seeded/unpicked.jsonl")
	walk.Selection = &selection
	return walk
}

func pickedBoth(head, mode string) Selection {
	return Selection{Mode: mode, HeadCommit: head, Picks: []Pick{
		{Check: "e2e/checks/seeded/landing.jsonl"}, {Check: "e2e/checks/unseeded/org-plane.jsonl"}}}
}

func TestAnUnpickedCheckIsOwedToTheFullRunAndIsNotAFault(t *testing.T) {
	walk := selectedWalk(pickedBoth("63c7793aaaa", SelectModeSelected))
	if err := walk.Err(); err != nil {
		t.Fatalf("an owed check is not a fault: %v", err)
	}
	if got := walk.Owed(); len(got) != 1 || got[0] != "e2e/checks/seeded/unpicked.jsonl" {
		t.Fatalf("owed %v", got)
	}
	section := walk.Markdown()
	for _, want := range []string{"owed to `make e2e-full`", "1 check(s) are owed"} {
		if !strings.Contains(section, want) {
			t.Fatalf("missing %q:\n%s", want, section)
		}
	}
	if strings.Contains(section, "every check ran against this build") {
		t.Fatalf("a selected walk must not claim the whole corpus ran:\n%s", section)
	}
}

func TestASelectionForAnotherHeadOwesNothing(t *testing.T) {
	walk := selectedWalk(pickedBoth("someotherhead", SelectModeSelected))
	if len(walk.Owed()) != 0 {
		t.Fatalf("owed %v", walk.Owed())
	}
	if err := walk.Err(); err == nil || !strings.Contains(err.Error(), "never run") {
		t.Fatalf("an unrun check under a stale selection is a fault: %v", err)
	}
}

func TestAFullRunOwesNothing(t *testing.T) {
	walk := selectedWalk(pickedBoth("63c7793aaaa", SelectModeFull))
	if err := walk.Err(); err == nil || !strings.Contains(err.Error(), "never run") {
		t.Fatalf("a full run that never reached a check leaves it never run: %v", err)
	}
}

func TestAPickedCheckThatDidNotRunIsStillAFault(t *testing.T) {
	selection := pickedBoth("63c7793aaaa", SelectModeSelected)
	selection.Picks = append(selection.Picks, Pick{Check: "e2e/checks/seeded/unpicked.jsonl"})
	walk := selectedWalk(selection)
	if err := walk.Err(); err == nil {
		t.Fatal("a picked check with no record is never run, not owed")
	}
}

// A hand-named run is not a selection: what it did not name was never run,
// not owed, or E2E_ONLY on one file would pass the Cover rung.
func TestAHandNamedRunOwesNothing(t *testing.T) {
	walk := selectedWalk(pickedBoth("63c7793aaaa", SelectModeNamed))
	if len(walk.Owed()) != 0 {
		t.Fatalf("owed %v", walk.Owed())
	}
	if err := walk.Err(); err == nil || !strings.Contains(err.Error(), "never run") {
		t.Fatalf("an unnamed check is never run: %v", err)
	}
}

// Selection reads the committed diff; on a dirty tree the uncommitted edits
// reached no check, so nothing can be owed.
func TestADirtySelectionOwesNothing(t *testing.T) {
	selection := pickedBoth("63c7793aaaa", SelectModeSelected)
	selection.Dirty = true
	walk := selectedWalk(selection)
	if err := walk.Err(); err == nil || !strings.Contains(err.Error(), "never run") {
		t.Fatalf("a dirty selection must not owe: %v", err)
	}
}
