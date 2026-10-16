// Command wakil-e2e-cover measures what the checks cover, and fails when
// newly added surface has no check.
//
// It is the standing audit of the design's §2 and, with --all, the discovery
// audit of §9.3 — one computation over two different surfaces, because two
// would be two answers to *what does covered mean*.
//
//	go run ./e2e/cmd/wakil-e2e-cover              # the gate: new surface only
//	go run ./e2e/cmd/wakil-e2e-cover --all        # the backlog: everything
//
// **No GUI and no launch.** The action denominator is only knowable from a
// live window, and `make e2e` already reads it on every launch and writes it
// down; this reads that record and refuses it when it describes another
// commit. So the gate is a pure computation over files that runs in the same
// second the checks finish, and cannot pass by being blind.
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	repo := flag.String("repo", ".", "the repository to read the branch's history from")
	trunk := flag.String("trunk", "origin/main", "what this branch forked from")
	evidence := flag.String("evidence", driver.DefaultEvidenceRoot,
		"where `make e2e` left the action denominator it observed")
	sources := flag.String("sources", driver.AppSourceRoot, "the Swift the controls are harvested from")
	exemptions := flag.String("uncoverable", driver.ExemptionFile,
		"surface no check can reach, and why")
	// **The backlog is a mode of the gate rather than a program of its own.**
	// It answers a different question — everything uncovered, not only what
	// this branch added — off the same denominators and the same coverage,
	// and it never fails a build.
	all := flag.Bool("all", false, "report every uncovered action and control, as a backlog rather than a gate")
	flag.Parse()

	if err := run(options{
		Repo:       *repo,
		Trunk:      *trunk,
		Evidence:   *evidence,
		Sources:    *sources,
		Exemptions: *exemptions,
		Checks:     flag.Args(),
		WholeTree:  *all,
	}); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-cover:", err)
		os.Exit(1)
	}
}

type options struct {
	Repo       string
	Trunk      string
	Evidence   string
	Sources    string
	Exemptions string
	Checks     []string
	WholeTree  bool
}

func run(opts options) error {
	audit, err := driver.AuditCoverage(driver.CoverageInputs{
		Repo:       opts.Repo,
		Trunk:      opts.Trunk,
		Evidence:   opts.Evidence,
		Sources:    opts.Sources,
		Exemptions: opts.Exemptions,
		Checks:     opts.Checks,
		WholeTree:  opts.WholeTree,
	})
	if err != nil {
		return err
	}
	// **What the audit had to say about its own inputs comes first**, so a
	// reader knows which build the numbers below describe before reading them.
	for _, note := range audit.Notes {
		fmt.Println("wakil-e2e-cover:", note)
	}
	if note := audit.BaseNote(); note != "" {
		fmt.Println("wakil-e2e-cover:", note)
	}
	report := audit.Report
	for _, line := range report.Counts() {
		fmt.Println("wakil-e2e-cover:", line)
	}
	fmt.Println("wakil-e2e-cover:", audit.ReadNote())

	// **Printed on every run, passing or not.** An entry here is a redirect
	// with a reason, never an exemption; a list nobody is reminded of is a
	// list that grows, which is the rule quarantine and backfill are already
	// held to.
	for _, gap := range report.Excused {
		fmt.Fprintln(os.Stderr, "wakil-e2e-cover: EXCUSED:", gap)
	}

	if opts.WholeTree {
		return printBacklog(report)
	}
	fmt.Println("wakil-e2e-cover:", report.NewSurfaceCount())
	return report.Err()
}

// printBacklog is the discovery audit: what nothing touches, anywhere, with no
// reference to a diff. **It never fails**, and that is the difference between
// a backlog and a gate — a list of work that turned a build red would be
// switched off, and this one is meant to be read.
func printBacklog(report driver.CoverageReport) error {
	gaps := report.Backlog()
	if len(gaps) == 0 {
		fmt.Println("wakil-e2e-cover: every action and every control is touched by a check")
		return nil
	}
	sort.Slice(gaps, func(i, j int) bool {
		if gaps[i].Kind != gaps[j].Kind {
			return gaps[i].Kind < gaps[j].Kind
		}
		return gaps[i].Name < gaps[j].Name
	})
	fmt.Printf("wakil-e2e-cover: %d piece(s) of surface no check touches — a backlog, not a gate\n",
		len(gaps))
	for _, gap := range gaps {
		fmt.Println("  " + gap.String())
	}
	return nil
}
