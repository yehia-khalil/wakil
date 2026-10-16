package driver

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// DefaultBundleCache is where bundles built from a commit are kept.
//
// Under `.context/`, which is gitignored, beside the evidence a red run
// leaves. A built bundle is several hundred megabytes and is derived from a
// commit, so it is exactly the kind of thing that must never reach the index.
const DefaultBundleCache = ".context/e2e/bundles"

// Command is one step of a bundle build.
type Command struct {
	Dir  string
	Name string
	Args []string
}

func (c Command) String() string {
	return fmt.Sprintf("%s %v (in %s)", c.Name, c.Args, c.Dir)
}

// BundlePlan is what building one commit's bundle takes.
//
// **A plan rather than a function that shells out**, because the two
// decisions worth testing — where the bundle goes, and what has to be run to
// get it there — are the ones a live build would otherwise cost several
// minutes to ask.
type BundlePlan struct {
	// Commit is the commit the bundle is built from.
	Commit string
	// Worktree is the checkout it is built in.
	Worktree string
	// Bundle is the Wakil.app the plan produces.
	Bundle string
	// Cached reports that the bundle is already there and Commands is empty.
	Cached   bool
	Commands []Command
}

// PlanBundle says how to get a bundle built from commit.
//
// **Keyed by the commit, in a worktree of its own.** A bundle built from
// another commit is the failure this whole target exists to prevent, so the
// cache cannot be keyed by anything a second commit could share — not a
// branch name, not "base", not a mtime.
//
// have reports whether a path exists; the caller passes the real filesystem
// and a test passes the state it wants to plan against.
func PlanBundle(repo, cache, commit string, have func(string) bool) BundlePlan {
	worktree := filepath.Join(cache, commit)
	plan := BundlePlan{
		Commit:   commit,
		Worktree: worktree,
		Bundle:   filepath.Join(worktree, "app", "Wakil.app"),
	}
	if have(plan.Bundle) {
		plan.Cached = true
		return plan
	}
	// **An existing worktree is resumed, not re-added.** `git worktree add`
	// refuses a directory that is already there, so an interrupted build —
	// the ordinary outcome of a `^C` during a five-minute `swift build` —
	// would otherwise be a hard failure rather than a cheap retry.
	if !have(worktree) {
		plan.Commands = append(plan.Commands, Command{
			Dir:  repo,
			Name: "git",
			Args: []string{"worktree", "add", "--detach", worktree, commit},
		})
	}
	// `app-bundle` alone: it already depends on `build` and `shaders`, and
	// naming those here would be a second answer to a question the Makefile
	// answers — the kind that gets updated in one place only.
	plan.Commands = append(plan.Commands, Command{
		Dir:  worktree,
		Name: "make",
		Args: []string{"app-bundle"},
	})
	return plan
}

// Execute runs the plan, naming the commit in any failure.
//
// A run that builds several bundles — retrodiction builds one per defect —
// would otherwise report an anonymous `make` failure with nothing saying
// which commit it was trying to build.
func (p BundlePlan) Execute(run func(Command) error) error {
	for _, command := range p.Commands {
		if err := run(command); err != nil {
			return fmt.Errorf("building the bundle at %s: %s: %w", p.Commit, command, err)
		}
	}
	return nil
}

// RunCommand executes one build step, streaming its output.
//
// **Streamed rather than captured.** `make app-bundle` runs `swift build`,
// which takes minutes; a captured build is a silent terminal for those
// minutes and then a wall of text, and an operator who cannot see progress
// cannot tell a slow build from a hung one.
func RunCommand(command Command) error {
	cmd := exec.Command(command.Name, command.Args...)
	cmd.Dir = command.Dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// BuildBundleAt builds, or reuses, the bundle for a commit and returns it.
func BuildBundleAt(repo, cache, commit string) (BundlePlan, error) {
	plan := PlanBundle(repo, cache, commit, pathExists)
	if plan.Cached {
		return plan, nil
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return plan, fmt.Errorf("making the bundle cache: %w", err)
	}
	if err := plan.Execute(RunCommand); err != nil {
		return plan, err
	}
	// **The bundle is verified to exist rather than assumed from exit 0.** A
	// `make` that succeeded without producing one would hand the runner a
	// path that does not exist, and the launch would fail several steps from
	// the cause.
	if !pathExists(plan.Bundle) {
		return plan, fmt.Errorf(
			"the build of %s reported success but left no bundle at %s", commit, plan.Bundle)
	}
	return plan, nil
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
