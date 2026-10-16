package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// **Every case names a check file that exists, and every patch is on disk.**
// A case pointing at a missing file fails the run several minutes in, after a
// build, with the operator's screen already taken.
func TestEveryRetrodictionNamesAFileThatExists(t *testing.T) {
	for _, retrodiction := range Retrodictions {
		if _, err := os.Stat("../../" + retrodiction.Check); err != nil {
			t.Errorf("%s: check %s: %v", retrodiction.Name, retrodiction.Check, err)
		}
		if _, err := os.Stat(retrodiction.PatchFile("../..")); err != nil {
			t.Errorf("%s: patch: %v", retrodiction.Name, err)
		}
	}
}

// **A case must say where the repo records the defect it puts back.** A
// reconstruction with no provenance is a mutation somebody invented, and
// measuring a check against an invented mutation measures the mutation.
func TestEveryRetrodictionCitesWhereTheDefectIsRecorded(t *testing.T) {
	for _, retrodiction := range Retrodictions {
		if strings.TrimSpace(retrodiction.Defect) == "" {
			t.Errorf("%s: no defect named", retrodiction.Name)
		}
		if strings.TrimSpace(retrodiction.Recorded) == "" {
			t.Errorf("%s: does not say where the defect is recorded", retrodiction.Name)
		}
	}
}

// **The tree is reset before each patch.** A case that ran before leaves its
// edit behind, and a second patch on top builds a bundle carrying two defects
// — which still goes red, and proves nothing about either.
func TestPlanRetrodictionResetsTheTreeBeforeApplying(t *testing.T) {
	plan := PlanRetrodiction("/repo", "/tree", Retrodictions[0])
	if len(plan.Commands) != 3 {
		t.Fatalf("want reset, apply and build, got %v", plan.Commands)
	}
	if plan.Commands[0].Name != "git" || plan.Commands[0].Args[0] != "checkout" {
		t.Fatalf("the first command must reset the tree, got %v", plan.Commands[0])
	}
	if plan.Commands[1].Args[0] != "apply" {
		t.Fatalf("the second must apply the patch, got %v", plan.Commands[1])
	}
	if plan.Commands[2].Name != "make" || plan.Commands[2].Dir != "/tree" {
		t.Fatalf("the build must run in the tree, got %v", plan.Commands[2])
	}
	if plan.Bundle != "/tree/app/Wakil.app" {
		t.Fatalf("got %q", plan.Bundle)
	}
	// **Never cached.** A reconstruction's "commit" is a case name, not a
	// tree, so a cache hit would silently reuse the previous case's bundle.
	if plan.Cached {
		t.Fatal("a reconstruction is rebuilt every time")
	}
}

// Each patch touches app sources only. A patch that edited the harness would
// be measuring the harness against itself.
func TestEveryRetrodictionPatchTouchesTheAppAndNotTheHarness(t *testing.T) {
	for _, retrodiction := range Retrodictions {
		if err := VerifyRetrodictionPatch("../..", retrodiction); err != nil {
			t.Errorf("%v", err)
		}
	}
}

// **The rule is enforced at run time, not only here.** `git apply --include`
// was measured to exit 0 and apply nothing when a patch falls outside the
// filter, so a violating patch was truncated rather than reported.
func TestVerifyRetrodictionPatchRefusesAPatchThatTouchesTheHarness(t *testing.T) {
	dir := t.TempDir()
	patch := "--- a/e2e/driver/run.go\n+++ b/e2e/driver/run.go\n@@ -1 +1 @@\n-a\n+b\n"
	if err := os.MkdirAll(filepath.Join(dir, RetrodictionPatches), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(dir, RetrodictionPatches, "bad.patch"), []byte(patch), 0o644); err != nil {
		t.Fatal(err)
	}
	err := VerifyRetrodictionPatch(dir, Retrodiction{Name: "bad"})
	if err == nil {
		t.Fatal("want a refusal")
	}
	if !strings.Contains(err.Error(), "e2e/driver/run.go") {
		t.Fatalf("the refusal must name the offending file, got %q", err)
	}
}

// A patch that writes to nothing reconstructs nothing, and would run its
// check against an unmodified build.
func TestVerifyRetrodictionPatchRefusesAPatchThatWritesNothing(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, RetrodictionPatches), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(dir, RetrodictionPatches, "empty.patch"), []byte("\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := VerifyRetrodictionPatch(dir, Retrodiction{Name: "empty"}); err == nil {
		t.Fatal("want a refusal")
	}
}
