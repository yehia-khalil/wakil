// Command wakil-e2e-retrodict puts 2c-iii's defects back and requires the
// checks to see them.
//
// **This is the acceptance criterion for the whole harness.** A harness that
// catches the mechanizable defects against the builds that carried them is
// proven; one that cannot is not, and that verdict has to land before any
// effort goes into the agent stub and beyond.
//
// **The builds that carried them do not exist.** 2c-iii was squash-merged, so
// the branch's own commits are gone from every ref. The nearest surviving
// build is the commit before the terminal pane, and running the seven against
// it proves only that they need a terminal pane — every one dies at the same
// step on the same missing identifier. So each defect is put back instead, by
// a patch removing one line whose absence the repo itself records as the
// cause, and the check that covers it must go red against the result.
//
//	go run ./e2e/cmd/wakil-e2e-retrodict
//	go run ./e2e/cmd/wakil-e2e-retrodict --case 1-profile-never-sourced
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	repo := flag.String("repo", ".", "the repository the patches and checks come from")
	tree := flag.String("tree", driver.DefaultRetrodictionTree, "the worktree reconstructions are built in")
	commit := flag.String("commit", "HEAD", "the commit the worktree is reset to")
	orcaPath := flag.String("orca", "", "the Orca CLI (default: the bundled one)")
	axresolvePath := flag.String("axresolve", "", "the identifier resolver (default: e2e/bin/axresolve)")
	only := flag.String("case", "", "run one case by name instead of all of them")
	verdictRoot := flag.String("verdict", ".context/e2e/retrodiction", "where the verdict is written")
	flag.Parse()

	if err := run(*repo, *tree, *commit, *orcaPath, *axresolvePath, *only, *verdictRoot); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-retrodict:", err)
		os.Exit(1)
	}
}

func run(repo, tree, commit, orcaPath, axresolvePath, only, verdictRoot string) (err error) {
	cases := driver.Retrodictions
	if only != "" {
		cases = nil
		for _, retrodiction := range driver.Retrodictions {
			if retrodiction.Name == only {
				cases = append(cases, retrodiction)
			}
		}
		if len(cases) == 0 {
			return fmt.Errorf("no retrodiction named %q", only)
		}
	}

	stamp := time.Now().UTC().Format("20060102-150405")
	prover, err := driver.ProverFor(
		orcaPath, axresolvePath, verdictRoot, stamp, "wakil-e2e-retrodict:   ")
	if err != nil {
		return err
	}
	if err := driver.EnsureRetrodictionTree(repo, tree, commit); err != nil {
		return err
	}
	// **Deferred, so EVERY path out leaves the tree clean.** It used to run
	// after the loop, which every failing path inside the loop returns before
	// — including the run error, which is the likeliest one: the AX grant
	// goes stale, and it did so twice during these runs. A worktree carrying
	// a case's patch is a build of Wakil with a defect in it, sitting on disk
	// under a name that does not say so, and the next `make app-bundle` in
	// that tree would quietly rebuild it.
	defer func() {
		reset := driver.Command{Dir: tree, Name: "git", Args: []string{"checkout", "--", "."}}
		if resetErr := driver.RunCommand(reset); resetErr != nil {
			resetErr = fmt.Errorf(
				"the retrodiction tree at %s still carries a defect patch and could not be "+
					"reset: %w", tree, resetErr)
			if err == nil {
				err = resetErr
			} else {
				fmt.Fprintln(os.Stderr, "wakil-e2e-retrodict:", resetErr)
			}
		}
	}()

	head, err := driver.HeadCommit(repo)
	if err != nil {
		return err
	}
	dirty, err := driver.TreeIsDirty(repo)
	if err != nil {
		return err
	}
	verdict := driver.Verdict{HeadCommit: head, Dirty: dirty}

	for _, retrodiction := range cases {
		fmt.Printf("\nwakil-e2e-retrodict: %s — %s\n", retrodiction.Name, retrodiction.Defect)
		fmt.Printf("wakil-e2e-retrodict:   recorded at %s\n", retrodiction.Recorded)
		if retrodiction.Reconstructed {
			fmt.Println("wakil-e2e-retrodict:   the original cause did not survive the squash merge; " +
				"this patch reproduces the observable, not the cause")
		}

		// Refused before anything is built: a patch that reached outside
		// app/Sources would be measuring the harness against itself, and one
		// that writes nothing would run its check against an unmodified
		// build and report BLIND — sending a reader to the check instead of
		// to the patch.
		if err := driver.VerifyRetrodictionPatch(repo, retrodiction); err != nil {
			return err
		}
		plan := driver.PlanRetrodiction(repo, tree, retrodiction)
		if err := plan.Execute(driver.RunCommand); err != nil {
			return err
		}
		groups, err := driver.GroupChecks([]string{retrodiction.Check})
		if err != nil {
			return err
		}
		// A run error is fatal and never a red: with the defect deliberately
		// back in the build, everything going red because the harness could
		// not reach the window is the easiest possible false pass. Prover
		// holds that rule for both commands.
		if err := prover.Prove(&verdict, groups[0], plan.Bundle); err != nil {
			return err
		}
		last := verdict.Checks[len(verdict.Checks)-1]
		if last.Red {
			fmt.Printf("wakil-e2e-retrodict:   SAW IT: %s\n", last.Failures[0])
		} else {
			fmt.Printf("wakil-e2e-retrodict:   BLIND: %s passed with the defect back in\n", last.Name)
		}
	}

	path, err := driver.WriteVerdict(verdictRoot, stamp, verdict)
	if err != nil {
		return err
	}
	fmt.Printf("\nwakil-e2e-retrodict: recorded at %s\n", path)
	if err := verdict.Err(); err != nil {
		return fmt.Errorf("the harness is blind to a defect it was built to catch:\n  %w", err)
	}
	fmt.Printf("wakil-e2e-retrodict: all %d reconstructed defect(s) were caught\n", len(verdict.Checks))
	return nil
}
