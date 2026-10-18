package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// DefaultRetrodictionTree is the worktree reconstructions are built in.
//
// **One worktree, reused across cases**, so the Swift build is incremental
// after the first: a reconstruction changes one or two lines, and a fresh
// worktree per case would pay a full `swift build` for each of them.
const DefaultRetrodictionTree = ".context/e2e/retrodiction-tree"

// RetrodictionPatches is where the reconstructions live.
const RetrodictionPatches = "e2e/retrodiction"

// Retrodiction is one defect, reconstructed, and the check that must see it.
//
// **Why a reconstruction and not a historical build.** 2c-iii was
// squash-merged (`84de6f6`), so the builds that carried its twenty-one
// defects do not exist in any ref — the branch's own commits are gone. The
// nearest surviving build is `3bc0d1f`, the commit before the terminal pane,
// and running the seven against it proves only that they need a terminal
// pane: every one of them dies at the same step, on the same missing
// identifier, which is evidence about #250 and not about 2c-iii.
//
// So the defect is put back. Each patch removes ONE line whose absence the
// repo itself records as having caused the defect — `ShellIntegration.swift`
// says in its own comment what happens without the `.zprofile` source, and
// `TerminalStore.swift` says what publishing `grid: []` on the block surface
// did — and the check that covers it must go red against the result.
//
// **This is source mutation, which `make e2e-new` deliberately rejected**, and
// the difference is worth stating: `e2e-new` is a standing gate run on every
// branch, where a rebuild per check is unaffordable. This runs once, to answer
// whether the harness can see the defects it was built for, and there is no
// other instrument that can answer it.
type Retrodiction struct {
	// Name is the case, and the patch file's stem.
	Name string
	// Check is the check file that must go red.
	Check string
	// Defect is the shape being put back, in the walk's own words.
	Defect string
	// Recorded is where the repo records that shape.
	Recorded string
	// Reconstructed marks a case whose ORIGINAL cause did not survive the
	// squash merge and whose patch reproduces the observable rather than the
	// cause. It is a weaker claim and the write-up must carry it as one.
	Reconstructed bool
}

// Retrodictions are the defects that can be put back.
//
// **Not all seven, and the gaps are the finding.** Checks 2 and 4 cover claims
// the 2c-iii walk did not find a defect in — the phase-log is explicit that
// none of the twenty-one was in the PTY, the mark scanner or the block model —
// so there is no defect of theirs to reconstruct. Saying so is the honest
// verdict; inventing a mutation for them would measure the mutation.
var Retrodictions = []Retrodiction{
	{
		Name:     "1-profile-never-sourced",
		Check:    "e2e/checks/seeded/2c-iii-1-bundle-path.jsonl",
		Defect:   "the pane's shell cannot find anything the operator's profile puts on PATH",
		Recorded: "ShellIntegration.swift: \"Without this, `which kubectl` fails in Wakil.app and succeeds in every test\"",
	},
	{
		Name:     "2-no-live-prompt",
		Check:    "e2e/checks/seeded/2c-iii-3-live-prompt.jsonl",
		Defect:   "the pane had no live prompt at all — the view kept passing nil",
		Recorded: "phase-log.md 2026-09-18, \"two correct halves and no join\"; TerminalSnapshot.promptRow",
	},
	// "block surface" is TerminalStore.swift's own word at the line this
	// patch reconstructs ("This used to publish `[]` on the block surface"),
	// not a coinage here. north-star.md §9 names the two surfaces "block
	// history" and "live grid"; this case keeps the app's spelling so the
	// name and the code it reconstructs read as the same thing.
	{
		Name:     "3-grid-empty-on-the-block-surface",
		Check:    "e2e/checks/seeded/2c-iii-3-live-prompt.jsonl",
		Defect:   "the operator typed blind: grid published [] whenever the history was showing",
		Recorded: "TerminalStore.swift, final review Critical 2",
	},
	{
		Name:     "4-full-screen-never-takes-the-pane",
		Check:    "e2e/checks/seeded/2c-iii-5-full-screen.jsonl",
		Defect:   "a full-screen program does not take the pane",
		Recorded: "TerminalSnapshot.screen; runbook check 7",
	},
	// **Keyed on the SWITCH, not on the fixture's org names.** The first
	// version returned early when the org id ended "-two", which is
	// `SeedSpec.second()`'s own suffix — so the mutation was written against
	// the fixture and check 7's red was guaranteed by construction rather
	// than earned. Found in review. It now sets a flag in `switchOrg`, which
	// is the event the walk actually found, and the mutation knows nothing
	// about the check that has to catch it.
	{
		Name:          "5-switch-stops-the-journal",
		Check:         "e2e/checks/seeded/2c-iii-7-org-switch.jsonl",
		Defect:        "an organisation switch silently stopped every later command being journalled",
		Recorded:      "phase-log.md 2026-09-18; runbook item 9's clause added after the final review",
		Reconstructed: true,
	},
	{
		Name:          "6-pane-close-leaves-an-orphan",
		Check:         "e2e/checks/seeded/2c-iii-6-no-orphan.jsonl",
		Defect:        "a closed pane leaves its shell running",
		Recorded:      "runbook check 21; TerminalStore.close",
		Reconstructed: true,
	},
	// **Background agents: the two defects the design exists to rule out**,
	// put back as their observables. Neither shipped, so both are
	// reconstructions; each is keyed on the mechanism (the pin, the turn's
	// end), never on the fixture's places.
	{
		Name:          "7-a-switch-retargets-a-running-agent",
		Check:         "e2e/checks/agent/bg-agent-chip-return.jsonl",
		Defect:        "an agent's call made after the operator switched lands in the place on screen, not its own",
		Recorded:      "2026-10-16-background-agents-design.md, Testing; north-star.md Invariant 5 (amended by Decision 41)",
		Reconstructed: true,
	},
	{
		Name:          "8-a-chip-moves-the-operator-unasked",
		Check:         "e2e/checks/agent/bg-agent-chip-return.jsonl",
		Defect:        "an agent that finishes off screen takes the operator to its place instead of turning its chip",
		Recorded:      "2026-10-16-background-agents-design.md, Interaction Rules row 6; PRODUCT.md Rule 6",
		Reconstructed: true,
	},
}

// PatchFile is where this case's reconstruction lives.
//
// **Absolute whenever it can be made so**, because `git apply` runs with the
// WORKTREE as its working directory: a repo-relative path resolves against
// the wrong tree and fails with a bare "No such file or directory" naming a
// path that does exist, one directory over.
func (r Retrodiction) PatchFile(root string) string {
	path := filepath.Join(root, RetrodictionPatches, r.Name+".patch")
	absolute, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return absolute
}

// PlanRetrodiction says how to put one defect back and build it.
//
// **The tree is reset before the patch, every time.** A case that ran before
// leaves its own edit behind, and a second patch applied on top would build a
// bundle carrying two defects — which would still go red, and would prove
// nothing about either.
func PlanRetrodiction(repo, tree string, retrodiction Retrodiction) BundlePlan {
	plan := BundlePlan{
		Commit:   retrodiction.Name,
		Worktree: tree,
		Bundle:   filepath.Join(tree, "app", "Wakil.app"),
	}
	plan.Commands = []Command{
		{Dir: tree, Name: "git", Args: []string{"checkout", "--", "."}},
		{Dir: tree, Name: "git", Args: []string{"apply", retrodiction.PatchFile(repo)}},
		{Dir: tree, Name: "make", Args: []string{"app-bundle"}},
	}
	return plan
}

// EnsureRetrodictionTree makes the worktree the reconstructions build in.
//
// It is detached at the given commit — normally HEAD, so a reconstruction is
// measured against the branch's own code and not against something older.
func EnsureRetrodictionTree(repo, tree, commit string) error {
	if pathExists(tree) {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(tree), 0o755); err != nil {
		return fmt.Errorf("making the retrodiction tree's parent: %w", err)
	}
	return RunCommand(Command{
		Dir: repo, Name: "git",
		Args: []string{"worktree", "add", "--detach", tree, commit},
	})
}

// PatchedFiles lists the files a patch writes to.
func PatchedFiles(patch []byte) []string {
	var files []string
	for _, line := range strings.Split(string(patch), "\n") {
		if file, isTarget := strings.CutPrefix(line, "+++ b/"); isTarget {
			files = append(files, strings.TrimSpace(file))
		}
	}
	return files
}

// VerifyRetrodictionPatch refuses a reconstruction that touches anything but
// the app's own sources.
//
// **It REFUSES rather than filters, and that distinction was a review
// finding.** The first version passed `--include=app/Sources/*` to
// `git apply`, which — measured — exits 0 and silently applies nothing when a
// patch falls outside the filter. The guarantee held in effect, because a
// harness edit could not land; but a violating patch was truncated rather
// than reported, so a case that quietly reconstructed nothing would have run
// its check against an unmodified build and reported BLIND, sending a reader
// to the check instead of to the patch.
//
// A reconstruction that edited the harness would be measuring the harness
// against itself, which is the thing this must make impossible.
func VerifyRetrodictionPatch(repo string, retrodiction Retrodiction) error {
	patch, err := os.ReadFile(retrodiction.PatchFile(repo))
	if err != nil {
		return fmt.Errorf("%s: %w", retrodiction.Name, err)
	}
	files := PatchedFiles(patch)
	if len(files) == 0 {
		return fmt.Errorf("%s: the patch writes to no file at all, so it reconstructs nothing",
			retrodiction.Name)
	}
	for _, file := range files {
		if !strings.HasPrefix(file, "app/Sources/") {
			return fmt.Errorf(
				"%s: the patch writes to %s — a reconstruction changes the app, never the "+
					"harness, or it would be measuring the harness against itself",
				retrodiction.Name, file)
		}
	}
	return nil
}
