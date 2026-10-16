// Command wakil-e2e-new proves this branch's new checks failable.
//
// It runs ONLY the checks the branch added or changed, against a bundle built
// from the **merge-base**, and requires every one of them to go red.
//
// **A check that has never failed is not evidence.** A GUI check that
// resolved a stale index, found nothing and asserted nothing still exits 0 —
// the same scar `make test-live` carries, in a nastier form, because `go test`
// at least prints SKIP. A check that passes against the code from before the
// work is not testing the work.
//
// **Why this and not source mutation.** Mutation needs a rebuild per check.
// This needs one extra bundle build per branch, no new machinery, and it is
// the Build rung's existing test-first discipline applied to the GUI.
//
//	go run ./e2e/cmd/wakil-e2e-new
//	go run ./e2e/cmd/wakil-e2e-new --base <commit> e2e/checks/seeded/terminal-block.jsonl
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	repo := flag.String("repo", ".", "the repository to read the branch from")
	trunk := flag.String("trunk", "origin/main", "the branch the merge-base is taken against")
	base := flag.String("base", "", "build the bundle from this commit instead of the merge-base")
	orcaPath := flag.String("orca", "", "the Orca CLI (default: the bundled one)")
	axresolvePath := flag.String("axresolve", "", "the identifier resolver (default: e2e/bin/axresolve)")
	cache := flag.String("bundle-cache", driver.DefaultBundleCache, "where bundles built from a commit are kept")
	verdictRoot := flag.String("verdict", driver.DefaultVerdictRoot, "where the failability record is written")
	flag.Parse()

	if err := run(options{
		Repo:        *repo,
		Trunk:       *trunk,
		Base:        *base,
		OrcaPath:    *orcaPath,
		AXResolve:   *axresolvePath,
		Cache:       *cache,
		VerdictRoot: *verdictRoot,
		Checks:      flag.Args(),
	}); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-new:", err)
		os.Exit(1)
	}
}

type options struct {
	Repo        string
	Trunk       string
	Base        string
	OrcaPath    string
	AXResolve   string
	Cache       string
	VerdictRoot string
	// Checks, when non-empty, replaces the diff-derived selection. It is how
	// retrodiction names one check and one historical commit, and how an
	// operator re-proves a single check without a second branch.
	Checks []string
}

func run(opts options) error {
	baseCommit := opts.Base
	if baseCommit == "" {
		resolved, err := driver.MergeBase(opts.Repo, opts.Trunk)
		if err != nil {
			return err
		}
		baseCommit = resolved
	}
	head, err := driver.HeadCommit(opts.Repo)
	if err != nil {
		return err
	}
	dirty, err := driver.TreeIsDirty(opts.Repo)
	if err != nil {
		return err
	}

	// **A check named on the command line is never redirected.** Backfill
	// answers "the merge-base cannot prove this one"; naming a check
	// explicitly — with an explicit `--base` — IS the run that proves it, and
	// filtering those would make the mechanism eat its own evidence.
	// Measured in review: with the seven listed, the very command
	// `backfill.tsv` cites as where checks 2 and 4 were seen to fail
	// redirected all seven and ran nothing, so those two entries pointed at
	// evidence the mechanism had made unreproducible.
	checks, named := opts.Checks, len(opts.Checks) > 0
	if !named {
		checks, err = driver.ChangedChecks(opts.Repo, baseCommit)
		if err != nil {
			return err
		}
	}

	verdict := driver.Verdict{
		BaseRef:    opts.Trunk,
		BaseCommit: baseCommit,
		HeadCommit: head,
		Dirty:      dirty,
	}
	stamp := time.Now().UTC().Format("20060102-150405")

	// **A branch that added no checks is not a pass and not a failure.** It
	// proved nothing, the record says so in those words, and the target exits
	// 0 — whether the branch OWED a check is the coverage gate's question,
	// not this one's.
	if len(checks) == 0 {
		verdict.Note = fmt.Sprintf(
			"this branch added or changed no check files since %s, so no check was proved failable",
			driver.ShortCommit(baseCommit))
		fmt.Println("wakil-e2e-new:", verdict.Note)
		return record(opts.VerdictRoot, stamp, verdict)
	}

	// **Backfill is read before anything is built.** A check whose
	// failability was proved elsewhere is redirected rather than exempted,
	// and every entry is printed on every run — the rule quarantine already
	// holds to, because a list nobody is reminded of is a list that grows.
	backfill, err := driver.LoadBackfill(filepath.Join(opts.Repo, driver.BackfillFile))
	if err != nil {
		return err
	}
	redirected, toProve := driver.SplitBackfill(checks, backfill, named)
	for _, check := range redirected {
		fmt.Printf("wakil-e2e-new: BACKFILL: %s — seen to fail by %s\n", check, backfill[check])
		// **Recorded, not only printed.** The verdict is what the Cover rung
		// reads without being told where to look; a redirect that lived only
		// in stdout left `verdict.json` claiming the branch had no checks at
		// all on the mixed path.
		verdict.AddRedirect(check, backfill[check])
	}
	if len(toProve) == 0 {
		verdict.Note = fmt.Sprintf(
			"all %d new check(s) are backfill: they cover surface that already existed at %s, "+
				"so the merge-base cannot prove them failable and each names where it was",
			len(redirected), driver.ShortCommit(baseCommit))
		fmt.Println("wakil-e2e-new:", verdict.Note)
		return record(opts.VerdictRoot, stamp, verdict)
	}

	groups, err := driver.GroupChecks(toProve)
	if err != nil {
		return err
	}
	fmt.Printf("wakil-e2e-new: %d check(s) to prove since %s, in %d launch(es)\n",
		len(toProve), driver.ShortCommit(baseCommit), len(groups))

	// **Both tools are resolved before the base bundle is built.** A missing
	// `e2e/bin/axresolve` is knowable now and costs a five-minute build to
	// discover later.
	orcaExe, err := driver.ResolveOrca(opts.OrcaPath)
	if err != nil {
		return err
	}
	resolverExe, err := driver.ResolveAXResolve(opts.AXResolve)
	if err != nil {
		return err
	}
	// **And the scripted agent, for the same reason, when any group needs
	// one.** A branch with no agent check must not be made to run
	// `make e2e-agent` first, and one with an agent check must not discover
	// the stub is missing after a five-minute bundle build.
	agent, err := agentFixtureFor(groups)
	if err != nil {
		return err
	}

	plan, err := driver.BuildBundleAt(opts.Repo, opts.Cache, baseCommit)
	if err != nil {
		return err
	}
	if plan.Cached {
		fmt.Printf("wakil-e2e-new: reusing the bundle already built from %s\n", driver.ShortCommit(baseCommit))
	}
	fmt.Printf("wakil-e2e-new: driving %s\n", plan.Bundle)

	for _, group := range groups {
		loaded, err := driver.LoadChecks([]string{group.Path})
		if err != nil {
			return err
		}
		session := driver.Session{
			Bundle:       plan.Bundle,
			Orca:         driver.Orca{Exe: orcaExe},
			Resolver:     driver.Resolver{Exe: resolverExe},
			EvidenceRoot: evidenceRoot(opts.VerdictRoot, stamp),
			Seed:         group.Kind.Seed(),
			Log: func(format string, args ...interface{}) {
				fmt.Printf("wakil-e2e-new: "+format+"\n", args...)
			},
		}
		// **The stub is this branch's, and the bundle is the merge-base's.**
		// That is the same asymmetry the target is built on: the harness is
		// the one being used to judge, the app is the one being judged.
		if group.Kind.Agent() {
			session.Agent = agent
		}
		result, runErr := session.Run(loaded)
		// **A run that could not work is a hard failure, never a red.**
		// Everything going red because the harness could not reach the window
		// looks identical to success from here, and that is the one outcome a
		// red-required pass must refuse.
		if runErr != nil {
			return runErr
		}
		verdict.Add(group, result)
	}

	for _, check := range verdict.Checks {
		state := "GREEN — not failable"
		if check.Red {
			state = "red, as required"
		}
		fmt.Printf("wakil-e2e-new:   %-40s %s\n", check.Name, state)
	}
	if err := record(opts.VerdictRoot, stamp, verdict); err != nil {
		return err
	}
	// #305: what went red is also committed, one file per check, so a runbook
	// re-rendered after this branch merges still carries the proof.
	if verdict.GeneratedAt.IsZero() {
		verdict.GeneratedAt = time.Now().UTC()
	}
	if err := driver.WriteProofs(opts.Repo, verdict, driver.GitBlob(opts.Repo)); err != nil {
		return err
	}
	fmt.Printf("wakil-e2e-new: proofs written under %s — commit them with the checks\n", driver.ProofDir)
	if err := verdict.Err(); err != nil {
		return err
	}
	fmt.Printf("wakil-e2e-new: all %d new check(s) went red against %s, so each of them tests "+
		"something that build did not have\n", len(verdict.Checks), driver.ShortCommit(baseCommit))
	return nil
}

// record writes the failability record and says where it went.
//
// **A verdict that could not be written fails the target.** The record is
// what the Cover rung reads; a run whose verdict never landed has proved
// nothing that anything downstream can see.
func record(root, stamp string, verdict driver.Verdict) error {
	path, err := driver.WriteVerdict(root, stamp, verdict)
	if err != nil {
		return err
	}
	fmt.Printf("wakil-e2e-new: recorded at %s\n", path)
	return nil
}

// evidenceRoot keeps a red-required run's screenshots with its own verdict.
//
// Not `.context/e2e`, where `make e2e` leaves its failures: here a failing
// check is the WANTED outcome, and mixing the two directories would put
// evidence of success beside evidence of defects.
func evidenceRoot(verdictRoot, stamp string) string {
	return verdictRoot + "/" + stamp + "/evidence"
}

// agentFixtureFor resolves the scripted agent when a group needs it, and
// returns the empty fixture when none does.
func agentFixtureFor(groups []driver.Group) (driver.AgentFixture, error) {
	for _, group := range groups {
		if group.Kind.Agent() {
			return driver.ResolveAgentFixture("")
		}
	}
	return driver.AgentFixture{}, nil
}
