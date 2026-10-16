package driver

import (
	"fmt"
	"path/filepath"
)

// CheckCorpus is every check file that exists, in every launch.
//
// **A glob that matched nothing is left as it is**, so `LoadChecks` refuses a
// path that is not there rather than a caller silently measuring coverage
// against an empty corpus — the trap `make e2e`'s own loop is written around.
//
// **One list, because the gate and the runbook must count the same files.**
// The gate's denominator of checks and the rendered table's rows are the same
// question, and two copies of this would let a document report coverage of a
// corpus the gate was not measuring.
//
// **The launches come from `LaunchDirs`, not from a list written here.** This
// held two of the three directories while `GroupChecks` held all three, so
// every action and control the agent checks exercise was reported uncovered
// (#246); the two lists are now one.
func CheckCorpus() []string {
	var paths []string
	for _, dir := range LaunchDirs() {
		pattern := filepath.Join(dir, "*.jsonl")
		matched, err := filepath.Glob(pattern)
		if err != nil || len(matched) == 0 {
			paths = append(paths, pattern)
			continue
		}
		paths = append(paths, matched...)
	}
	return paths
}

// CoverageInputs is one coverage audit's inputs.
//
// A struct rather than six adjacent strings: transposing two of them would
// compile and would measure the wrong tree.
type CoverageInputs struct {
	// Repo is the repository the branch's history is read from, and Trunk is
	// what it forked from.
	Repo, Trunk string
	// Evidence is where `make e2e` left the actions it observed.
	Evidence string
	// Sources is the Swift the controls are harvested from, and Exemptions is
	// the uncoverable list.
	Sources, Exemptions string
	// Checks is the corpus. Empty takes CheckCorpus.
	Checks []string
	// WholeTree asks the backlog's question — everything uncovered, rather
	// than what this branch added. It reads no history and tolerates a
	// denominator from another build, saying which.
	WholeTree bool
}

// CoverageAudit is what one audit amounts to: the verdict, and what a caller
// needs to say how it was reached.
type CoverageAudit struct {
	Report CoverageReport
	// Checks is how many check files were read, and Files how many paths were
	// asked for.
	Checks, Files int
	// BaseCommit is the merge-base the newness question was answered against,
	// and SourceFiles how many Swift files were read there. Both are empty on
	// a whole-tree audit, which asks no question about a diff.
	BaseCommit  string
	SourceFiles int
	// Notes are what the audit has to say about its own inputs — a
	// denominator from another build, or one observed from a dirty tree.
	// **Returned rather than printed**, so the caller that renders a document
	// and the caller that prints to a terminal say the same things.
	Notes []string
}

// AuditCoverage is the standing audit and the discovery audit, in one
// computation.
//
// **One pipeline, because two callers ask the same question.**
// `wakil-e2e-cover` asks it to fail a build and `wakil-e2e-runbook` asks it to
// write a document, and the day two copies diverged the document would certify
// a gate that was enforcing something else. They had already diverged once, on
// whether a denominator observed from a dirty tree is worth mentioning.
//
// **No GUI and no launch.** The action denominator is only knowable from a
// live window, and every `make e2e` launch records what it heard; this reads
// that, and refuses a record observed against another commit — measured
// against an older build the gate cannot see the action this branch added, and
// would pass by being blind.
func AuditCoverage(in CoverageInputs) (CoverageAudit, error) {
	paths := in.Checks
	if len(paths) == 0 {
		paths = CheckCorpus()
	}
	// **The checks are loaded first, and an empty corpus is refused** — by
	// LoadChecks, for the reason it already gives. Here it would do worse than
	// prove nothing: coverage of no checks is zero, so every piece of surface
	// would be reported, and the first thing anyone would learn is to ignore
	// this.
	checks, err := LoadChecks(paths)
	if err != nil {
		return CoverageAudit{}, err
	}
	audit := CoverageAudit{Checks: len(checks), Files: len(paths)}

	head, err := HeadCommit(in.Repo)
	if err != nil {
		return CoverageAudit{}, err
	}
	denominator, err := ReadDenominator(in.Evidence)
	if err != nil {
		return CoverageAudit{}, err
	}
	// **The gate refuses a stale denominator; the backlog only says so.** A
	// gate measured against an older build cannot see the action this branch
	// just added and would pass by being blind, which is the one way a gate
	// must never pass. A backlog measured against an older build is a list of
	// work that is a commit out of date — still worth reading, as long as the
	// line above it says which commit it describes.
	if err := denominator.Err(head); err != nil {
		if !in.WholeTree {
			return CoverageAudit{}, err
		}
		audit.Notes = append(audit.Notes, denominator.StaleNote(head))
	}
	if denominator.Dirty {
		audit.Notes = append(audit.Notes, "the actions were observed from a tree carrying "+
			"uncommitted changes, so they describe that tree rather than the commit")
	}

	identifiers, err := HarvestIdentifiers(in.Sources)
	if err != nil {
		return CoverageAudit{}, err
	}
	whole := Surface{Actions: denominator.Actions(), Identifiers: identifiers}

	// **The backlog asks no question about a diff, so it reads no history.**
	// That is a property of where it can be RUN as much as of what it reports:
	// reading the merge-base here would make an unfetched `origin/main` or a
	// shallow clone turn the backlog into an error, and a list that will not
	// print where you happen to be standing is a list nobody consults.
	var fresh Surface
	if !in.WholeTree {
		added, err := FreshSurface(in.Repo, in.Trunk, whole)
		if err != nil {
			return CoverageAudit{}, err
		}
		fresh = added.Surface
		audit.BaseCommit, audit.SourceFiles = added.BaseCommit, added.SourceFiles
	}
	excused, err := LoadExemptions(in.Exemptions)
	if err != nil {
		return CoverageAudit{}, err
	}
	audit.Report = Judge(whole, fresh, CoverageOf(checks), excused)
	return audit, nil
}

// ReadNote describes the corpus this audit measured, for the line a run
// prints.
func (a CoverageAudit) ReadNote() string {
	return fmt.Sprintf("%d check(s) read from %d file(s)", a.Checks, a.Files)
}

// BaseNote describes the commit the newness question was answered against. It
// is empty on a whole-tree audit, which asked none.
func (a CoverageAudit) BaseNote() string {
	if a.BaseCommit == "" {
		return ""
	}
	return fmt.Sprintf("new since %s (%d source(s) read)", ShortCommit(a.BaseCommit), a.SourceFiles)
}
