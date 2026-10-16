package driver

import (
	"strings"
	"testing"
)

func TestNewChecksTakesAddedAndModifiedCheckFiles(t *testing.T) {
	diff := strings.Join([]string{
		"A\te2e/checks/seeded/terminal-block.jsonl",
		"M\te2e/checks/seeded/vocabulary.jsonl",
	}, "\n")
	selected := NewChecks(diff)
	want := []string{
		"e2e/checks/seeded/terminal-block.jsonl",
		"e2e/checks/seeded/vocabulary.jsonl",
	}
	if len(selected) != len(want) {
		t.Fatalf("want %v, got %v", want, selected)
	}
	for i, path := range want {
		if selected[i] != path {
			t.Fatalf("want %v, got %v", want, selected)
		}
	}
}

// **A modified check counts, and that is the whole reason the filter is not
// "added" alone.** A step appended to an existing file is a claim that has
// never been seen to fail exactly as much as a new file is, and it is the
// commoner shape: a check grows as a surface grows.

// Everything outside the check directories is ignored, because the target
// runs check files and nothing else. A branch that changed the driver, the
// Makefile and one check has one new check.
func TestNewChecksIgnoresEverythingThatIsNotACheckFile(t *testing.T) {
	diff := strings.Join([]string{
		"M\te2e/driver/run.go",
		"M\tMakefile",
		"A\te2e/checks/seeded/terminal-block.jsonl",
		"A\tdocs/wakil/phase-log.md",
		"A\te2e/checks/seeded/notes.md",
	}, "\n")
	selected := NewChecks(diff)
	if len(selected) != 1 || selected[0] != "e2e/checks/seeded/terminal-block.jsonl" {
		t.Fatalf("want the one check file, got %v", selected)
	}
}

// A deleted check cannot be run, and a renamed one is the same check under a
// new name — its content was never touched, so nothing about it is unproven.
// Neither may reach the runner: a selection carrying a path that is not on
// disk fails the whole target for a reason that has nothing to do with
// failability.
func TestNewChecksSkipsDeletionsAndRenames(t *testing.T) {
	diff := strings.Join([]string{
		"D\te2e/checks/seeded/gone.jsonl",
		"R100\te2e/checks/seeded/old.jsonl\te2e/checks/seeded/new.jsonl",
	}, "\n")
	if selected := NewChecks(diff); len(selected) != 0 {
		t.Fatalf("want nothing selected, got %v", selected)
	}
}

// A branch that added no checks is not an error here. **It is not a pass
// either**, and saying which of the two it is belongs to the verdict, not to
// the selection.
func TestNewChecksOnABranchThatTouchedNoChecksIsEmpty(t *testing.T) {
	if selected := NewChecks("M\tinternal/wakilcore/provider.go\n"); len(selected) != 0 {
		t.Fatalf("want nothing selected, got %v", selected)
	}
}

// **One launch per check file.** Checks that share an instance couple through
// its state, and the coupling is invisible in the files: `vocabulary.jsonl`
// addresses `terminal-1` only because nothing before it opened a pane, and
// 2c-iii's organisation-switch check closes every pane on the canvas. Run
// together, the order of the files is part of the meaning of each of them.
func TestGroupChecksGivesEachCheckItsOwnLaunch(t *testing.T) {
	groups, err := GroupChecks([]string{
		"e2e/checks/unseeded/org-plane.jsonl",
		"e2e/checks/seeded/landing.jsonl",
		"e2e/checks/seeded/vocabulary.jsonl",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(groups) != 3 {
		t.Fatalf("want one launch per check, got %d: %v", len(groups), groups)
	}
	// Unseeded first, matching `make e2e`'s own order: the organisation plane
	// is the cheaper launch and fails faster when the bundle is unusable.
	if groups[0].Kind.Seed() || groups[0].Path != "e2e/checks/unseeded/org-plane.jsonl" {
		t.Fatalf("want the unseeded check first, got %v", groups[0])
	}
	for _, group := range groups[1:] {
		if !group.Kind.Seed() {
			t.Fatalf("want the seeded checks after it, got %v", group)
		}
	}
}

// **A check outside the known directories is refused rather than guessed
// at.** Launching it seeded when it wanted the organisation plane produces a
// red that says nothing about the check, and under --expect-red that red would
// be read as proof.
func TestGroupChecksRefusesACheckInNoKnownLaunch(t *testing.T) {
	_, err := GroupChecks([]string{"e2e/checks/terminal-block.jsonl"})
	if err == nil {
		t.Fatal("want an error for a check in no known launch")
	}
	if !strings.Contains(err.Error(), "e2e/checks/terminal-block.jsonl") {
		t.Fatalf("the error must name the path it could not place, got %q", err)
	}
	// The refusal names every directory there is, because a reader who put a
	// check in the wrong one has to be told which ones exist — and the agent
	// directory is the one that was missing from both the code and this
	// sentence.
	for _, dir := range []string{UnseededDir, SeededDir, AgentDir} {
		if !strings.Contains(err.Error(), dir) {
			t.Fatalf("the refusal must name %s, got %q", dir, err)
		}
	}
}

// **An agent check is a launch of its own kind, and #284 is what it cost not
// to say so.** `e2e/checks/agent/` arrived with #255 and this did not, so
// every branch that touched a check in it failed `make e2e-new` with "is in
// neither seeded nor unseeded" — the Cover rung declining to run at all, on a
// branch whose whole subject was the agent checks. A gate that cannot be run
// is not a gate.
func TestGroupChecksPutsAnAgentCheckInASeededLaunchThatCarriesTheAgent(t *testing.T) {
	groups, err := GroupChecks([]string{
		"e2e/checks/agent/both-surfaces.jsonl",
		"e2e/checks/seeded/vocabulary.jsonl",
		"e2e/checks/unseeded/org-plane.jsonl",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(groups) != 3 {
		t.Fatalf("want one launch per check, got %d: %v", len(groups), groups)
	}
	// Unseeded, seeded, agent — cheapest and least able to fail spuriously
	// first, so a bundle that cannot be driven says so before the agent is
	// ever started.
	want := []Group{
		{Kind: UnseededLaunch, Path: "e2e/checks/unseeded/org-plane.jsonl"},
		{Kind: SeededLaunch, Path: "e2e/checks/seeded/vocabulary.jsonl"},
		{Kind: AgentLaunch, Path: "e2e/checks/agent/both-surfaces.jsonl"},
	}
	for index, group := range groups {
		if group != want[index] {
			t.Fatalf("launch %d = %+v, want %+v", index, group, want[index])
		}
	}
}

// An agent check is seeded as well as agent-carrying: the scripted agent
// answers about an organisation's panes, and an unseeded instance has none.
func TestGroupChecksSeedsAnAgentLaunch(t *testing.T) {
	groups, err := GroupChecks([]string{"e2e/checks/agent/two-enter.jsonl"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !groups[0].Kind.Seed() {
		t.Fatalf("an agent launch must be seeded, got %+v", groups[0])
	}
	if !groups[0].Kind.Agent() {
		t.Fatalf("an agent launch must carry the agent, got %+v", groups[0])
	}
}

// **There are three launches and there is no fourth.** The pair of booleans
// this replaced could spell "agent, unseeded" — an agent with no organisation
// to answer about — which would have gone red for a reason that had nothing to
// do with the check. A kind cannot spell it.
func TestEveryLaunchKindIsSeededExceptTheUnseededOne(t *testing.T) {
	for kind, wantSeed := range map[LaunchKind]bool{
		UnseededLaunch: false,
		SeededLaunch:   true,
		AgentLaunch:    true,
	} {
		if kind.Seed() != wantSeed {
			t.Fatalf("%s.Seed() = %v, want %v", kind, kind.Seed(), wantSeed)
		}
	}
	if !AgentLaunch.Agent() {
		t.Fatal("the agent launch must be the one that carries the agent")
	}
	for _, kind := range []LaunchKind{UnseededLaunch, SeededLaunch} {
		if kind.Agent() {
			t.Fatalf("%s must not carry the agent", kind)
		}
	}
	// Named, because a verdict a person reads should not make them decode two
	// booleans to learn which launch produced it.
	for kind, want := range map[LaunchKind]string{
		UnseededLaunch: "unseeded", SeededLaunch: "seeded", AgentLaunch: "agent",
	} {
		if kind.String() != want {
			t.Fatalf("String() = %q, want %q", kind.String(), want)
		}
	}
}
