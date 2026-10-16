package driver

import (
	"fmt"
	"strings"
	"testing"
)

// nothingOnDisk is the state of a first run: no worktree, no bundle.
func nothingOnDisk(string) bool { return false }

func TestPlanBundleBuildsAWorktreeAndThenTheBundle(t *testing.T) {
	plan := PlanBundle("/repo", "/cache", "abc1234", nothingOnDisk)
	if plan.Cached {
		t.Fatal("nothing is on disk, so nothing is cached")
	}
	if plan.Bundle != "/cache/abc1234/app/Wakil.app" {
		t.Fatalf("the bundle must be inside the commit's own worktree, got %q", plan.Bundle)
	}
	if len(plan.Commands) != 2 {
		t.Fatalf("want a worktree and a build, got %v", plan.Commands)
	}
	add := plan.Commands[0]
	if add.Name != "git" || !strings.Contains(strings.Join(add.Args, " "), "worktree add") {
		t.Fatalf("the first command must create the worktree, got %v", add)
	}
	if !strings.Contains(strings.Join(add.Args, " "), "abc1234") {
		t.Fatalf("the worktree must be checked out at the commit, got %v", add)
	}
	build := plan.Commands[1]
	if build.Name != "make" || build.Dir != "/cache/abc1234" {
		t.Fatalf("the build must run in the worktree, got %v", build)
	}
	// **app-bundle and nothing else.** It already depends on `build` and
	// `shaders`, and naming those here would be a second answer to a question
	// the Makefile answers.
	if len(build.Args) != 1 || build.Args[0] != "app-bundle" {
		t.Fatalf("want `make app-bundle`, got %v", build.Args)
	}
}

// **A built bundle is reused, and that is what makes retrodiction affordable.**
// Seven historical builds at several minutes each is an afternoon; seven
// cached ones is nothing. The key is the commit, so a cache hit can never be
// a different tree.
func TestPlanBundleReusesABundleAlreadyBuiltForThatCommit(t *testing.T) {
	have := func(path string) bool { return path == "/cache/abc1234/app/Wakil.app" }
	plan := PlanBundle("/repo", "/cache", "abc1234", have)
	if !plan.Cached {
		t.Fatal("want a cache hit")
	}
	if len(plan.Commands) != 0 {
		t.Fatalf("a cache hit runs nothing, got %v", plan.Commands)
	}
	if plan.Bundle != "/cache/abc1234/app/Wakil.app" {
		t.Fatalf("got %q", plan.Bundle)
	}
}

// An interrupted build leaves the worktree behind without a bundle in it.
// `git worktree add` refuses an existing directory, so a plan that always
// added one would turn a resumable state into a hard failure.
func TestPlanBundleResumesAWorktreeWhoseBuildDidNotFinish(t *testing.T) {
	have := func(path string) bool { return path == "/cache/abc1234" }
	plan := PlanBundle("/repo", "/cache", "abc1234", have)
	if plan.Cached {
		t.Fatal("a worktree with no bundle in it is not a cache hit")
	}
	if len(plan.Commands) != 1 || plan.Commands[0].Name != "make" {
		t.Fatalf("want the build alone, with no second worktree add, got %v", plan.Commands)
	}
}

// A failure says which commit's build failed. `make app-bundle` names nothing
// about the ref, and a run that builds several of them (retrodiction) would
// otherwise report an anonymous build failure.
func TestExecuteBundlePlanNamesTheCommitWhoseBuildFailed(t *testing.T) {
	plan := PlanBundle("/repo", "/cache", "abc1234", nothingOnDisk)
	err := plan.Execute(func(command Command) error {
		if command.Name == "make" {
			return fmt.Errorf("metal toolchain not installed")
		}
		return nil
	})
	if err == nil {
		t.Fatal("want the build failure")
	}
	if !strings.Contains(err.Error(), "abc1234") {
		t.Fatalf("the failure must name the commit, got %q", err)
	}
	if !strings.Contains(err.Error(), "metal toolchain") {
		t.Fatalf("the failure must carry what make said, got %q", err)
	}
}

func TestExecuteBundlePlanRunsNothingOnACacheHit(t *testing.T) {
	have := func(path string) bool { return path == "/cache/abc1234/app/Wakil.app" }
	plan := PlanBundle("/repo", "/cache", "abc1234", have)
	if err := plan.Execute(func(command Command) error {
		t.Fatalf("a cache hit must run nothing, ran %v", command)
		return nil
	}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
