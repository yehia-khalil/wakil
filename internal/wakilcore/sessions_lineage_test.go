package wakilcore

import (
	"path/filepath"
	"testing"
)

func TestSessionParent_RoundTrips(t *testing.T) {
	setupHome(t)
	if err := RecordSessionParent("child-1", "parent-1"); err != nil {
		t.Fatalf("RecordSessionParent: %v", err)
	}
	got, err := SessionParent("child-1")
	if err != nil {
		t.Fatalf("SessionParent: %v", err)
	}
	if got != "parent-1" {
		t.Errorf("SessionParent = %q, want parent-1", got)
	}
}

func TestSessionParent_UnknownChildIsEmptyNotAnError(t *testing.T) {
	setupHome(t)
	got, err := SessionParent("never-recorded")
	if err != nil {
		t.Fatalf("SessionParent: %v", err)
	}
	if got != "" {
		t.Errorf("SessionParent = %q, want empty", got)
	}
}

func TestSessionParents_AbsentStoreIsAnEmptyMap(t *testing.T) {
	setupHome(t)
	got, err := SessionParents()
	if err != nil {
		t.Fatalf("SessionParents: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("SessionParents = %v, want empty", got)
	}
}

func TestRecordSessionParent_IsPerOrg(t *testing.T) {
	setupHome(t) // pins WAKIL_ORG=initech
	if err := RecordSessionParent("child-1", "parent-1"); err != nil {
		t.Fatalf("RecordSessionParent: %v", err)
	}
	// A second org must not see it. Invariant 4: the org directory is a
	// boundary cross-org bleed must be structurally unable to cross.
	if err := CreateOrg("other", Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	t.Setenv("WAKIL_ORG", "other")
	got, err := SessionParent("child-1")
	if err != nil {
		t.Fatalf("SessionParent: %v", err)
	}
	if got != "" {
		t.Errorf("org \"other\" sees %q — the store leaked across orgs", got)
	}
}

func TestListSessions_ReportsTheParentOfAFork(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "child-1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "hi"}},
	})
	if err := RecordSessionParent("child-1", "parent-1"); err != nil {
		t.Fatalf("RecordSessionParent: %v", err)
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(got.Sessions) != 1 {
		t.Fatalf("len = %d, want 1", len(got.Sessions))
	}
	if got.Sessions[0].Parent != "parent-1" {
		t.Errorf("Parent = %q, want parent-1", got.Sessions[0].Parent)
	}
}

// LineageRootIn is the identity a conversation keeps across every resume
// that forked it, and it is a storage key — so these pin termination as
// hard as they pin the happy path. The write path does not reject a
// self-parent or a cycle, so neither is hypothetical.

func TestLineageRootOfAFreshSessionIsItself(t *testing.T) {
	if got := LineageRootIn(map[string]string{}, "a"); got != "a" {
		t.Fatalf("a session with no recorded parent is its own root; got %q", got)
	}
}

func TestLineageRootWalksAChainToItsOldestAncestor(t *testing.T) {
	// f resumed e resumed d ... resumed a — six sessions, one conversation.
	parents := map[string]string{"f": "e", "e": "d", "d": "c", "c": "b", "b": "a"}
	for _, id := range []string{"a", "b", "c", "d", "e", "f"} {
		if got := LineageRootIn(parents, id); got != "a" {
			t.Fatalf("every member of a chain resolves to the same root; %q gave %q", id, got)
		}
	}
}

func TestLineageRootOfAnIdAbsentFromTheMapIsItself(t *testing.T) {
	parents := map[string]string{"b": "a"}
	if got := LineageRootIn(parents, "z"); got != "z" {
		t.Fatalf("an unrecorded session is its own root; got %q", got)
	}
}

func TestLineageRootTreatsAnEmptyParentAsNone(t *testing.T) {
	// RecordSessionParent stores what it is given; "" is what a caller
	// writing a root's own entry would leave.
	if got := LineageRootIn(map[string]string{"a": ""}, "a"); got != "a" {
		t.Fatalf("an empty parent means no parent; got %q", got)
	}
}

func TestLineageRootTerminatesOnASelfParent(t *testing.T) {
	// A -> A. Nobody's parent but its own, so it survives every filter a
	// caller might apply and reaches the walk.
	if got := LineageRootIn(map[string]string{"a": "a"}, "a"); got != "a" {
		t.Fatalf("a self-parent resolves to itself; got %q", got)
	}
}

func TestLineageRootTerminatesOnACycle(t *testing.T) {
	// A -> B -> A, reached from C, which points into the cycle without
	// being in it. The answer is arbitrary because the data is malformed;
	// what matters is that it is an answer rather than a hang.
	parents := map[string]string{"c": "a", "a": "b", "b": "a"}
	got := LineageRootIn(parents, "c")
	if got != "a" && got != "b" {
		t.Fatalf("a cycle must terminate inside itself; got %q", got)
	}
}

func TestLineageRootOfAnEmptyIdIsEmpty(t *testing.T) {
	if got := LineageRootIn(map[string]string{"a": "b"}, ""); got != "" {
		t.Fatalf("no id, no root; got %q", got)
	}
}
