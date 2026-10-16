// wakil-e2e-select chooses which check files a run takes and records why.
//
// Stdout is the file list, one per line, in launch order — the Makefile runs
// exactly that. Everything a reader needs is on stderr.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	repo := flag.String("repo", ".", "the repository whose branch is selected for")
	trunk := flag.String("trunk", "origin/main", "what this branch forked from")
	evidence := flag.String("evidence", driver.DefaultEvidenceRoot, "where the selection record goes")
	only := flag.Bool("only", false, "run exactly the files named (E2E_ONLY)")
	full := flag.Bool("full", false, "run exactly the files named, as the whole suite (make e2e-full)")
	flag.Parse()

	sel, err := choose(*repo, *trunk, *only, *full, flag.Args())
	if err == nil {
		err = record(*evidence, sel)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-select:", err)
		os.Exit(1)
	}
	for _, file := range sel.Files() {
		fmt.Println(file)
	}
}

func choose(repo, trunk string, only, full bool, named []string) (driver.Selection, error) {
	var sel driver.Selection
	var err error
	switch {
	case only && full:
		return sel, fmt.Errorf("--only and --full are two different runs; pass one")
	case only:
		sel, err = driver.NamedSelection(driver.SelectModeNamed, named)
	case full:
		sel, err = driver.NamedSelection(driver.SelectModeFull, named)
	default:
		sel, err = selectForBranch(repo, trunk)
	}
	if err != nil {
		return sel, err
	}
	if sel.HeadCommit, err = driver.HeadCommit(repo); err != nil {
		return sel, err
	}
	sel.Dirty, err = driver.TreeIsDirty(repo)
	return sel, err
}

func selectForBranch(repo, trunk string) (driver.Selection, error) {
	base, err := driver.MergeBase(repo, trunk)
	if err != nil {
		return driver.Selection{}, err
	}
	changes, err := driver.ChangedFiles(repo, base)
	if err != nil {
		return driver.Selection{}, err
	}
	corpus, err := driver.LoadCorpus(driver.CheckCorpus())
	if err != nil {
		return driver.Selection{}, err
	}
	sel := driver.SelectChecks(changes, corpus)
	sel.BaseCommit = base
	return sel, nil
}

func record(root string, sel driver.Selection) error {
	path, err := driver.WriteSelection(root, sel)
	if err != nil {
		return err
	}
	say := func(format string, args ...any) { fmt.Fprintf(os.Stderr, "wakil-e2e-select: "+format+"\n", args...) }
	switch sel.Mode {
	case driver.SelectModeSelected:
		say("%d check(s) reached by the diff since %s", len(sel.Picks), driver.ShortCommit(sel.BaseCommit))
	default:
		say("%d check(s), %s", len(sel.Picks), sel.Mode)
	}
	for _, p := range sel.Picks {
		reasons := p.Reasons
		more := ""
		if len(reasons) > 3 {
			more = fmt.Sprintf(" (and %d more)", len(reasons)-3)
			reasons = reasons[:3]
		}
		say("  %s — %s%s", p.Check, strings.Join(reasons, "; "), more)
	}
	if len(sel.Unmapped) > 0 {
		say("UNMAPPED — no check reaches these; only `make e2e-full` covers them:")
		for _, file := range sel.Unmapped {
			say("  %s", file)
		}
	}
	if len(sel.NoCheck) > 0 {
		say("declare controls no check presses (the coverage gate's question): %s", strings.Join(sel.NoCheck, ", "))
	}
	if len(sel.Ignored) > 0 {
		say("%d file(s) ignored: docs, proofs, tests and Markdown cannot change what a check sees", len(sel.Ignored))
	}
	if sel.Mode == driver.SelectModeSelected && len(sel.Picks) == 1 {
		say("nothing beyond the org-plane check is reached, so this run proves only that the bundle starts")
	}
	if sel.Dirty {
		say("the tree has uncommitted changes; selection read the committed diff only")
	}
	say("recorded in %s", path)
	return nil
}
