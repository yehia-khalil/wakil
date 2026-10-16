// Command wakil-e2e runs the end-to-end checks against a fixture instance of
// the Wakil bundle.
//
// It is a program rather than a `go test` package on purpose. The design
// (§3) proposed putting e2e/ behind `//go:build e2e` so `make test` would not
// try to drive a GUI; a program achieves that without a tag, and without also
// excluding the library's own unit tests — which are the guards that stop a
// check silently asserting nothing, and therefore the last thing that should
// be hidden behind a tag.
//
//	go run ./e2e/cmd/wakil-e2e --bundle app/Wakil.app e2e/checks/seeded/*.jsonl
//	go run ./e2e/cmd/wakil-e2e --bundle app/Wakil.app --no-seed e2e/checks/unseeded/*.jsonl
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	bundle := flag.String("bundle", "app/Wakil.app", "the Wakil.app to drive")
	orcaPath := flag.String("orca", "", "the Orca CLI (default: the bundled one)")
	root := flag.String("fixture", "", "fixture root (default: a fresh directory under TMPDIR)")
	// **Seeding is a property of the RUN, not of a check file.** An instance
	// either has an org on disk and open or it does not, and the two cases want
	// different assertions: e2e/checks/unseeded asserts the organisation plane
	// ("NO ORGANISATION IS OPEN"), e2e/checks/seeded asserts what is behind it.
	// One launch cannot satisfy both, so `make e2e` runs one pass per state
	// rather than teaching the check format a fixture directive. #251 extended
	// that format with `do`, `dispatch` and `parity` and deliberately did not
	// add a fixture directive: seeding stays a property of the run, because a
	// check file that could reseed mid-flight would describe a state no single
	// launch is in.
	noSeed := flag.Bool("no-seed", false, "launch with no seeded org, for the organisation-plane checks")
	axresolvePath := flag.String("axresolve", "", "the identifier resolver (default: e2e/bin/axresolve)")
	// **The scripted agent is opt-in per run, because most checks do not want
	// one.** A fixture whose provider record names no binary opens with no
	// agent, which is the state every check before #255 was written against;
	// `make e2e` asks for the stub only on the check files that drive it.
	agentStub := flag.String("agent", "", "seed the scripted agent onto the provider record (default: no agent)")
	evidenceRoot := flag.String("evidence", driver.DefaultEvidenceRoot,
		"where a run leaves its screenshot, tree, pane snapshot and the actions it observed")
	// **Quarantine is a flag, not a file the runner keeps.** An intermittent
	// check is quarantined deliberately, by name, in the command that runs it,
	// and reported on every run — never retried into green.
	quarantine := flag.String("quarantine", "", "comma-separated names of known-intermittent checks to report rather than fail on")
	// **A deadline for a predicate, and the lever a diagnosis needs.** Zero
	// lets the launch choose — three seconds, or AgentSettle when it carries
	// the agent — and a negative duration asks for no waiting at all. What it
	// is for is the differential in #284: running the same check at the old
	// deadline and the new one, under the same load, is the only way to show
	// a flake was latency and not a defect.
	settle := flag.Duration("settle", 0, "how long an assertion waits for its predicate (default: the launch's own)")
	flag.Parse()

	if err := run(options{
		Bundle:       *bundle,
		OrcaPath:     *orcaPath,
		AXResolve:    *axresolvePath,
		AgentStub:    *agentStub,
		FixtureRoot:  *root,
		EvidenceRoot: *evidenceRoot,
		Seed:         !*noSeed,
		Quarantined:  splitQuarantine(*quarantine),
		Settle:       *settle,
		Checks:       flag.Args(),
	}); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e:", err)
		os.Exit(1)
	}
	fmt.Println("wakil-e2e: all checks passed")
}

// options is one run's inputs.
//
// A struct rather than eight positional parameters, five of them adjacent
// untyped strings: transposing two of those would compile and would run the
// checks against the wrong directory.
type options struct {
	Bundle       string
	OrcaPath     string
	AXResolve    string
	AgentStub    string
	FixtureRoot  string
	EvidenceRoot string
	Seed         bool
	Quarantined  []string
	Settle       time.Duration
	Checks       []string
}

func run(opts options) error {
	checks, err := driver.LoadChecks(opts.Checks)
	if err != nil {
		return err
	}

	exe, err := driver.ResolveOrca(opts.OrcaPath)
	if err != nil {
		return err
	}

	// **Both tools are resolved before anything is staged or launched.** The
	// resolver used to be looked up after the seed, the staging, the launch
	// and the MCP handshake, so a missing `e2e/bin/axresolve` — the ordinary
	// state of a fresh clone — killed the run only after paying for a whole
	// launch, to say something knowable at the start.
	resolverExe, err := driver.ResolveAXResolve(opts.AXResolve)
	if err != nil {
		return err
	}

	// **Resolved before anything is staged or launched**, for the reason the
	// two tools above are: a missing stub is knowable at the start, and
	// discovering it after a launch costs the launch.
	var agent driver.AgentFixture
	if opts.AgentStub != "" {
		if agent, err = driver.ResolveAgentFixture(agentStubOverride(opts.AgentStub)); err != nil {
			return err
		}
	}

	session := driver.Session{
		Bundle:       opts.Bundle,
		Orca:         driver.Orca{Exe: exe},
		Resolver:     driver.Resolver{Exe: resolverExe},
		FixtureRoot:  opts.FixtureRoot,
		EvidenceRoot: opts.EvidenceRoot,
		Seed:         opts.Seed,
		Quarantined:  opts.Quarantined,
		Settle:       opts.Settle,
		Agent:        agent,
		Log:          func(format string, args ...interface{}) { fmt.Printf("wakil-e2e: "+format+"\n", args...) },
	}
	result, runErr := session.Run(checks)
	fmt.Printf("wakil-e2e: %d check(s), %d assertion(s)\n", result.ChecksRun, result.Assertions)
	recordDenominator(opts, result)
	recordRuns(opts, result, runErr)
	// **A quarantined check is reported every run.** A quarantine nobody is
	// reminded of is a check that has been deleted without anyone deciding to.
	for _, note := range result.Quarantined {
		fmt.Fprintln(os.Stderr, "wakil-e2e: QUARANTINED:", note)
	}
	if runErr != nil {
		return runErr
	}
	return result.Err()
}

// recordDenominator writes down the actions this launch saw, for the coverage
// gate that runs after the checks.
//
// **Recorded whatever the checks did.** The list is what the window ANSWERED
// at launch, before a check ran; a red run's denominator is exactly as true as
// a green one's, and dropping it would leave the gate reading the previous
// run's — which is to say, describing another build.
//
// **A failure to write it is reported and does not fail the run.** The gate
// refuses a missing record loudly and by name, so the failure is already
// caught where it means something; failing the checks here would report a
// bookkeeping fault as a defect in the app.
func recordDenominator(opts options, result driver.Result) {
	if len(result.Tools) == 0 {
		return
	}
	// The repository is the working directory: `make e2e` runs this from the
	// root, and the record's whole job is to say which commit it describes.
	head, err := driver.HeadCommit(".")
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e: could not read HEAD, so the actions observed "+
			"cannot be attributed to a commit:", err)
		return
	}
	dirty, err := driver.TreeIsDirty(".")
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e: could not read the working tree's state:", err)
		return
	}
	path, err := driver.WriteDenominator(opts.EvidenceRoot, driver.Denominator{
		HeadCommit: head, Dirty: dirty, Bundle: opts.Bundle, Tools: result.Tools,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e: could not record the actions observed:", err)
		return
	}
	fmt.Printf("wakil-e2e: %d action(s) recorded in %s\n", len(result.Tools), path)
}

// recordRuns writes down what this launch did to each check file it was given,
// for the machine section of an acceptance runbook.
//
// **One record per check file, not per launch.** The file is the record's
// identity, because one launch per check file is this target's own rule and a
// run of the whole corpus is therefore a directory of files rather than a
// history of launches. A second run of a file replaces its record.
//
// **The launch's fault, when there was one, reaches every file's record.** A
// bundle that would not stage or a channel that never opened says nothing
// about which check was at fault, and a file recorded green under it would be
// a green walk of a launch that did not happen.
//
// **A failure to write it is reported and does not fail the run**, for
// recordDenominator's reason: the reader that needs this refuses a missing
// record by name, so the failure is caught where it means something.
func recordRuns(opts options, result driver.Result, runErr error) {
	head, err := driver.HeadCommit(".")
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e: could not read HEAD, so this run cannot be "+
			"attributed to a commit:", err)
		return
	}
	dirty, err := driver.TreeIsDirty(".")
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e: could not read the working tree's state:", err)
		return
	}
	for _, file := range opts.Checks {
		// **A record is keyed by the check's PATH and narrowed by its BASE
		// NAME**, because that is how the harness already names a check:
		// `LoadChecks` calls it `filepath.Base(path)` and the runner reports
		// outcomes under that name, while the two fixture directories can hold
		// files of the same name — so the record needs the path and the lookup
		// has only the name.
		record := driver.RunRecordOf(
			driver.Group{Kind: launchKind(opts), Path: file},
			result.For(filepath.Base(file)),
			runErr)
		record.HeadCommit, record.Dirty, record.Bundle = head, dirty, opts.Bundle
		if _, err := driver.WriteRunRecord(opts.EvidenceRoot, record); err != nil {
			// **The next file is still recorded.** Abandoning the loop here
			// contradicted this function's own rule that a bookkeeping failure
			// does not fail the run, and did it in the worst way: the files it
			// skipped render later as checks that were never run.
			fmt.Fprintln(os.Stderr, "wakil-e2e: could not record what this run did:", err)
			continue
		}
	}
}

// agentStubOverride reads the --agent flag: `on` takes the built stub, and
// anything else is a path to a specific one. **A named path is used or the run
// fails**, which is ResolveOrca's rule — a caller that named a build must never
// be handed a different one.
func agentStubOverride(value string) string {
	if value == "on" {
		return ""
	}
	return value
}

// splitQuarantine reads the --quarantine list. An empty flag quarantines
// nothing, and a blank entry is dropped rather than becoming a check named "".
func splitQuarantine(value string) []string {
	var names []string
	for _, name := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(name); trimmed != "" {
			names = append(names, trimmed)
		}
	}
	return names
}

// launchKind names which of the three launches this run is, for the record it
// writes. `wakil-e2e` is told by flags rather than by a directory — it runs
// whatever file it is handed — so the kind is derived here rather than by
// `GroupChecks`.
func launchKind(opts options) driver.LaunchKind {
	switch {
	case opts.AgentStub != "":
		return driver.AgentLaunch
	case opts.Seed:
		return driver.SeededLaunch
	default:
		return driver.UnseededLaunch
	}
}
