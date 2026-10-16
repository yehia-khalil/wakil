// Command wakil-e2e-runbook renders the machine half of an acceptance
// runbook from what the harness actually left behind.
//
// The Cover rung's three conditions, in one section: every check ran green
// against this build (`make e2e`), every check this branch added was seen to
// fail against the merge-base (`make e2e-new`), and the surface the branch
// added carries checks (the coverage gate).
//
//	go run ./e2e/cmd/wakil-e2e-runbook                                        # to stdout
//	go run ./e2e/cmd/wakil-e2e-runbook --into docs/wakil/phase-2c-iii-acceptance.md
//
// **Nothing here is typed by hand, and that is the point.** The runbook's
// human half is prose the operator writes and walks; its machine half is a
// claim about a run, and a claim about a run written by the agent that made
// the run is what the Walk rung's *"Never an agent"* exists to refuse. This
// reads the records — `.context/e2e/runs/`, `.context/e2e/new/latest.json`,
// `.context/e2e/actions.json` — and renders what they say.
//
// **No GUI and no launch**, for the coverage gate's reason: everything it
// needs was written down by the runs that already happened, and a record that
// describes another commit is refused rather than rendered.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	repo := flag.String("repo", ".", "the repository to read the branch's history from")
	trunk := flag.String("trunk", "origin/main", "what this branch forked from")
	evidence := flag.String("evidence", driver.DefaultEvidenceRoot,
		"where the runs left their records, and the actions they observed")
	verdicts := flag.String("verdicts", driver.DefaultVerdictRoot,
		"where `make e2e-new` left what it proved")
	sources := flag.String("sources", driver.AppSourceRoot, "the Swift the controls are harvested from")
	exemptions := flag.String("uncoverable", driver.ExemptionFile,
		"surface no check can reach, and why")
	into := flag.String("into", "",
		"an acceptance runbook to splice the section into, between its machine-walk markers")
	// **A red walk still renders.** The section says it is red, in the
	// harness's own words, and the exit status carries the verdict — so a
	// caller that wants the rung's answer reads the status, and the runbook
	// never silently keeps the last green run.
	flag.Parse()

	if err := run(options{
		Repo:       *repo,
		Trunk:      *trunk,
		Evidence:   *evidence,
		Verdicts:   *verdicts,
		Sources:    *sources,
		Exemptions: *exemptions,
		Into:       *into,
		Checks:     flag.Args(),
	}); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-runbook:", err)
		os.Exit(1)
	}
}

type options struct {
	Repo       string
	Trunk      string
	Evidence   string
	Verdicts   string
	Sources    string
	Exemptions string
	Into       string
	Checks     []string
}

func run(opts options) error {
	corpus := opts.Checks
	if len(corpus) == 0 {
		corpus = driver.CheckCorpus()
	}
	head, err := driver.HeadCommit(opts.Repo)
	if err != nil {
		return err
	}
	dirty, err := driver.TreeIsDirty(opts.Repo)
	if err != nil {
		return err
	}
	records, err := driver.ReadRunRecords(opts.Evidence)
	if err != nil {
		return err
	}
	verdict, proved, err := driver.ReadLatestVerdict(opts.Verdicts)
	if err != nil {
		return err
	}

	walk := driver.MachineWalk{
		HeadCommit: head,
		Dirty:      dirty,
		Corpus:     corpus,
		Runs:       records,
	}
	if proved {
		walk.Verdict = &verdict
	}
	selection, selected, err := driver.ReadSelection(opts.Evidence)
	if err != nil {
		return err
	}
	if selected {
		if selection.HeadCommit != head {
			fmt.Fprintf(os.Stderr, "wakil-e2e-runbook: the selection record names %s, not %s, so it is ignored\n",
				driver.ShortCommit(selection.HeadCommit), driver.ShortCommit(head))
		}
		walk.Selection = &selection
	}
	// #305: the committed proofs answer for checks this verdict does not cover.
	proofs, err := driver.LoadProofs(opts.Repo)
	if err != nil {
		return err
	}
	walk.Proofs = proofs
	walk.Blobs = map[string]string{}
	blobOf := driver.GitBlob(opts.Repo)
	for _, file := range corpus {
		if blob, err := blobOf(file); err == nil {
			walk.Blobs[file] = blob
		}
	}
	// **The coverage verdict is computed rather than read**, because the gate
	// writes none: it is a pure computation over the check files, the
	// harvested identifiers and the actions a run observed. It goes through
	// `driver.AuditCoverage`, which is the gate's own pipeline and not a
	// second copy of it — a document that computed coverage its own way would
	// certify a gate that was enforcing something else.
	audit, err := driver.AuditCoverage(driver.CoverageInputs{
		Repo:       opts.Repo,
		Trunk:      opts.Trunk,
		Evidence:   opts.Evidence,
		Sources:    opts.Sources,
		Exemptions: opts.Exemptions,
		Checks:     corpus,
	})
	if err != nil {
		// A denominator from another build, or none at all, leaves coverage
		// UNKNOWN — which MachineWalk records as an unmet condition rather
		// than as a passing one. The section must never read green on a
		// question nothing asked.
		fmt.Fprintln(os.Stderr, "wakil-e2e-runbook: coverage is unknown:", err)
		walk.CoverageErr = err
	} else {
		walk.Coverage = &audit.Report
		walk.Notes = audit.Notes
	}

	section := walk.Markdown()
	if opts.Into == "" {
		fmt.Println(section)
		return walk.Err()
	}
	if err := splice(opts.Into, section); err != nil {
		return err
	}
	fmt.Printf("wakil-e2e-runbook: the machine section of %s now describes %s\n",
		opts.Into, driver.ShortCommit(head))
	return walk.Err()
}

// splice replaces the machine section of a runbook in place.
func splice(path, section string) error {
	document, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	spliced, err := driver.SpliceMachineWalk(string(document), section)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return os.WriteFile(path, []byte(spliced), 0o644)
}
