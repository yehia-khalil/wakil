package driver

import (
	"fmt"
	"os/exec"
	"path"
	"sort"
	"strings"
)

// CheckRoot is where check files live, and the prefix selection matches on.
const CheckRoot = "e2e/checks/"

// The launch states, as directories under CheckRoot.
//
// **Seeding is a property of the run, not of a check file** — the reasoning is
// in wakil-e2e's own flag comment. So the directory a check sits in is what
// says which launch it belongs to, and there is nowhere else to put that fact.
//
// **AgentDir is seeded AND carries the scripted agent**, which is why it is a
// third directory rather than a flag inside a seeded check: a launch either
// put the stub on the provider record before it started or it did not, and
// nothing a check file says can change that afterwards. #255 added the
// directory and not this; every branch that touched a check in it since then
// failed `make e2e-new` outright — "is in neither seeded nor unseeded" —
// which is the Cover rung refusing to run rather than a check failing, and
// the two read nothing alike (#284).
const (
	SeededDir   = CheckRoot + "seeded/"
	UnseededDir = CheckRoot + "unseeded/"
	AgentDir    = CheckRoot + "agent/"
)

// launchDirs pairs every launch with the directory its checks live in, in the
// order a run should take them.
//
// **One list, because the runner and the auditor were reading two.**
// `GroupChecks` knew three directories and `CheckCorpus` knew two, so
// `e2e/checks/agent/` was run by `make e2e-agent-checks` and invisible to the
// coverage gate — which reported the surface those checks exercise as
// untouched, and would have accepted a second check written for it. Anything
// that needs to enumerate the launches reads this, so the next directory can
// only be added in one place (#246).
//
// **Unseeded first**, matching `make e2e`'s own order: the organisation plane
// is the cheaper launch and fails faster when the bundle itself is unusable.
// **Agent last**, for the same reason inverted: the most expensive launch and
// the most ways to fail, so a bundle that cannot be driven at all says so
// before one of them is started.
var launchDirs = []struct {
	Kind LaunchKind
	Dir  string
}{
	{UnseededLaunch, UnseededDir},
	{SeededLaunch, SeededDir},
	{AgentLaunch, AgentDir},
}

// LaunchDirs is where checks live, one directory per launch, in run order.
func LaunchDirs() []string {
	dirs := make([]string, 0, len(launchDirs))
	for _, launch := range launchDirs {
		dirs = append(dirs, launch.Dir)
	}
	return dirs
}

// LaunchFor reports which launch a check file's path puts it in.
//
// A kind that reaches here without a directory in launchDirs matches nothing
// and is refused by name, rather than defaulting into someone else's launch
// and producing a red that says nothing about the check.
func LaunchFor(file string) (LaunchKind, bool) {
	for _, launch := range launchDirs {
		if strings.HasPrefix(file, launch.Dir) {
			return launch.Kind, true
		}
	}
	return 0, false
}

// Group is one launch: a fixture state, and the check file to run against an
// instance in it.
//
// **One check file per launch, and that is a rule rather than a default.**
// Checks that share an instance couple through its state, and the coupling is
// invisible in the check files themselves: `vocabulary.jsonl` addresses
// `terminal-1` and `terminal-2`, which are the ids only because nothing
// before it opened a pane, and 2c-iii's organisation-switch check closes
// every pane on the canvas and leaves a different org open. Run in one
// launch, the order of the files is part of the meaning of each of them, and
// nothing in a file says so.
//
// The cost is a launch each — a handful of seconds — and what it buys is that
// a check file is a statement about the app rather than about its position in
// a sequence.
type Group struct {
	Kind LaunchKind
	Path string
}

// LaunchKind is which of the three launches a check wants.
//
// **One value, not two booleans.** It was `Seed bool` plus `Agent bool`, with
// "Agent implies Seed" written in a comment and enforced only by the single
// arm of `GroupChecks` that built the pair — so `{Seed: false, Agent: true}`,
// an agent launch with no organisation for the agent to answer about, was
// representable and would have produced a red that said nothing about the
// check. There are three launches and there is no fourth; naming them makes
// the missing one unwritable rather than merely undocumented.
type LaunchKind int

const (
	// UnseededLaunch opens on the organisation plane, with nothing on disk.
	UnseededLaunch LaunchKind = iota
	// SeededLaunch opens with an organisation, and no agent.
	SeededLaunch
	// AgentLaunch is seeded AND carries the scripted agent on the fixture's
	// provider record. Seeded because the agent answers about an
	// organisation's panes, and an unseeded instance has none.
	AgentLaunch
)

// Seed reports whether this launch puts an organisation on disk and opens it.
func (k LaunchKind) Seed() bool { return k != UnseededLaunch }

// Agent reports whether this launch seeds the scripted agent.
func (k LaunchKind) Agent() bool { return k == AgentLaunch }

// String names the launch, for a verdict a person reads.
func (k LaunchKind) String() string {
	switch k {
	case UnseededLaunch:
		return "unseeded"
	case SeededLaunch:
		return "seeded"
	case AgentLaunch:
		return "agent"
	default:
		return fmt.Sprintf("LaunchKind(%d)", int(k))
	}
}

// NewChecks selects the check files a branch added or changed.
//
// diff is `git diff --name-status <merge-base>...HEAD`, unfiltered. The filter
// lives here rather than in the git invocation so that the rules — which
// statuses count, and what a check file is — are readable and testable in one
// place instead of being spelled as flags in a Makefile recipe.
//
// **Added and modified both count.** A step appended to an existing check is
// a claim that has never been seen to fail exactly as much as a new file is,
// and it is the commoner shape as a surface grows.
//
// **Deleted and renamed do not.** A deleted check cannot be run at all, and a
// rename leaves the content untouched, so nothing about it became unproven.
// Selecting either would fail the target for a reason that has nothing to do
// with failability.
func NewChecks(diff string) []string {
	var selected []string
	for _, line := range strings.Split(diff, "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) < 2 {
			continue
		}
		// A rename or copy carries a similarity score (R100, C75) and two
		// paths; neither status is selected, so the score never has to be read.
		switch fields[0] {
		case "A", "M":
		default:
			continue
		}
		file := fields[len(fields)-1]
		if !strings.HasPrefix(file, CheckRoot) || path.Ext(file) != ".jsonl" {
			continue
		}
		selected = append(selected, file)
	}
	sort.Strings(selected)
	return selected
}

// GroupChecks turns a selection into the launches that run it — one per check
// file, in the fixture state its directory names.
//
// **Unseeded first**, matching `make e2e`'s own order: the organisation plane
// is the cheaper launch and fails faster when the bundle itself is unusable.
//
// A check in neither directory is refused rather than placed by guess. Running
// an organisation-plane check against a seeded instance produces a red that
// says nothing about the check — and under a red-required run, that red would
// be read as proof.
func GroupChecks(paths []string) ([]Group, error) {
	byLaunch := make(map[LaunchKind][]Group, len(launchDirs))
	for _, file := range paths {
		kind, ok := LaunchFor(file)
		if !ok {
			return nil, fmt.Errorf(
				"%s is in none of %s, so there is no way to know which launch it wants, "+
					"and guessing would produce a result that proves nothing",
				file, strings.Join(LaunchDirs(), ", "))
		}
		byLaunch[kind] = append(byLaunch[kind], Group{Kind: kind, Path: file})
	}
	var groups []Group
	for _, launch := range launchDirs {
		groups = append(groups, byLaunch[launch.Kind]...)
	}
	return groups, nil
}

// MergeBase returns the commit this branch forked from.
//
// **The merge-base, never the tip of the trunk.** A branch whose trunk has
// moved on would otherwise be proved against code it was never written
// against: a check could go red on a change someone else made, which is
// exactly the false evidence this target exists to refuse.
func MergeBase(repo, trunk string) (string, error) {
	out, err := exec.Command("git", "-C", repo, "merge-base", trunk, "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("finding the merge-base with %s: %w", trunk, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// ChangedChecks lists the check files this branch added or changed since base.
func ChangedChecks(repo, base string) ([]string, error) {
	out, err := exec.Command("git", "-C", repo, "diff", "--name-status", base+"...HEAD").Output()
	if err != nil {
		return nil, fmt.Errorf("listing what changed since %s: %w", base, err)
	}
	return NewChecks(string(out)), nil
}

// HeadCommit is the commit the branch is on.
func HeadCommit(repo string) (string, error) {
	out, err := exec.Command("git", "-C", repo, "rev-parse", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("reading HEAD: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// TreeIsDirty reports whether the working tree carries uncommitted changes.
//
// **Recorded rather than refused.** An operator iterating on a check runs this
// target constantly with a dirty tree, and refusing would make the loop
// unusable; but a verdict taken from a dirty tree does not describe the
// commit, and only the record can say which it was.
func TreeIsDirty(repo string) (bool, error) {
	out, err := exec.Command("git", "-C", repo, "status", "--porcelain").Output()
	if err != nil {
		return false, fmt.Errorf("reading the working tree's state: %w", err)
	}
	return strings.TrimSpace(string(out)) != "", nil
}
