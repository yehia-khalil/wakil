package driver

import (
	"fmt"
	"path/filepath"
)

// Prover runs one check against one bundle and records what it did.
//
// **The layer below Session, extracted for the same reason Session was.**
// `wakil-e2e-new` and `wakil-e2e-retrodict` both build a bundle, launch it,
// run one check against it, refuse a run error, and add the outcome to a
// verdict — and both had their own copy of that sequence, including their own
// spelling of the evidence directory. The rule that matters most is the one
// in the middle:
//
// **A run that could not work is a hard failure, never a red.** Both callers
// require their checks to FAIL, so everything going red because the harness
// could not reach the window is, from inside either of them, indistinguishable
// from total success. That rule now has one home.
type Prover struct {
	Orca     Orca
	Resolver Resolver
	// VerdictRoot and Stamp locate this run's evidence.
	VerdictRoot string
	Stamp       string
	// Log is where the session narrates itself.
	Log func(format string, args ...interface{})
}

// EvidenceRoot is where a failing check leaves what it saw.
//
// Under the run's own verdict directory rather than `.context/e2e`, where
// `make e2e` leaves its failures: in a red-required run a failing check is
// the WANTED outcome, and mixing the two would put evidence of success beside
// evidence of defects.
func (p Prover) EvidenceRoot() string {
	return filepath.Join(p.VerdictRoot, p.Stamp, "evidence")
}

// Prove runs one group's check against a bundle and adds the outcome to the
// verdict, returning a run error the caller must treat as fatal.
func (p Prover) Prove(verdict *Verdict, group Group, bundle string) error {
	loaded, err := LoadChecks([]string{group.Path})
	if err != nil {
		return err
	}
	// **An agent group needs the stub, and a run that quietly dropped it
	// would be the worst outcome this file has.** The check would go red
	// because nothing answered it, which under a red-required run reads as
	// proof — the exact confusion the header's rule exists to refuse.
	var agent AgentFixture
	if group.Kind.Agent() {
		resolved, agentErr := ResolveAgentFixture("")
		if agentErr != nil {
			return agentErr
		}
		agent = resolved
	}
	result, runErr := (Session{
		Bundle:       bundle,
		Orca:         p.Orca,
		Resolver:     p.Resolver,
		EvidenceRoot: p.EvidenceRoot(),
		Seed:         group.Kind.Seed(),
		Agent:        agent,
		Log:          p.Log,
	}).Run(loaded)
	if runErr != nil {
		return runErr
	}
	verdict.Add(group, result)
	return nil
}

// ProverFor resolves both tools and returns a Prover, or says which one is
// missing.
//
// **Both are resolved before anything is built.** A missing
// `e2e/bin/axresolve` — the ordinary state of a fresh clone — is knowable now
// and costs a multi-minute bundle build to discover later.
func ProverFor(orcaPath, axresolvePath, verdictRoot, stamp, prefix string) (Prover, error) {
	orcaExe, err := ResolveOrca(orcaPath)
	if err != nil {
		return Prover{}, err
	}
	resolverExe, err := ResolveAXResolve(axresolvePath)
	if err != nil {
		return Prover{}, err
	}
	return Prover{
		Orca:        Orca{Exe: orcaExe},
		Resolver:    Resolver{Exe: resolverExe},
		VerdictRoot: verdictRoot,
		Stamp:       stamp,
		Log: func(format string, args ...interface{}) {
			fmt.Printf(prefix+format+"\n", args...)
		},
	}, nil
}
