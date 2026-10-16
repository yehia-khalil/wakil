package driver

import (
	"fmt"
	"os"
	"strings"
)

// BackfillFile lists checks whose failability was proved somewhere other than
// against the merge-base.
const BackfillFile = "e2e/checks/backfill.tsv"

// LoadBackfill reads the backfill list: a check path, a tab, and where its
// failability IS proved.
//
// **Backfill is the case the design's §8 did not cover, and #253 is the
// specimen.** `make e2e-new` proves a branch's new checks failable against the
// merge-base, on the premise that a check accompanies the work it tests.
// 2c-iii's seven check surface that shipped on 2026-09-18, five days before
// that branch forked, so all seven PASS against the merge-base and the target
// correctly refuses them. The premise does not apply; the target is right.
//
// **An entry is a redirect, never an exemption.** It says where the check was
// seen to fail, it is printed on every run and recorded in the verdict — the
// same rule quarantine holds to, because a list nobody is reminded of is a
// list that grows — and a reviewer reads the reason.
//
// **What refuses what.** This loader refuses an entry with no reason, which
// is the one rule it can enforce without reading the rest of the repository.
// An entry naming a check that is not on disk, or pointing at a retrodiction
// case that does not exist, is refused by `make test` — see
// backfill_test.go's two live-file tests. Neither pretends to judge whether a
// reason is a GOOD reason, because neither can; a reviewer does that.
//
// A missing file is not an error: most branches have none, and requiring one
// would make the ordinary case carry a file full of nothing.
func LoadBackfill(path string) (map[string]string, error) {
	return loadRedirects(path,
		"a backfill entry is a redirect to where the check WAS seen to fail, and an entry "+
			"with no reason is an exemption nobody has to justify")
}

// loadRedirects reads a redirect list: a name, a tab, and a reason.
//
// **One reader, because there are two of these files and they are the same
// file.** `backfill.tsv` redirects a check's failability and
// `uncoverable.tsv` redirects a piece of surface's coverage; both refuse an
// entry with no reason, both are printed on every run, and both grow the
// moment they stop being read. Two loaders would be two answers to one format,
// and the second would learn a lesson the first had already learnt.
//
// A missing file is not an error: most branches have neither, and requiring
// one would make the ordinary case carry a file full of nothing. What cannot
// be judged here is whether a reason is a GOOD reason — a reviewer does that,
// and pretending to do it here would only teach people to write whatever this
// accepts. `what` is the caller's sentence about its own list, so the refusal
// says what was expected in the words of the file the reader is looking at.
func loadRedirects(path, what string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	entries := map[string]string{}
	for index, line := range strings.Split(string(data), "\n") {
		text := strings.TrimSpace(line)
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		name, reason, tabbed := strings.Cut(text, "\t")
		name = strings.TrimSpace(name)
		reason = strings.TrimSpace(reason)
		if !tabbed || reason == "" {
			return nil, fmt.Errorf("%s line %d: %q names no reason — %s",
				path, index+1, name, what)
		}
		entries[name] = reason
	}
	return entries, nil
}

// retrodictionPrefix is how a reason names a retrodiction case.
const retrodictionPrefix = "make e2e-retrodict:"

// RetrodictionNamedBy reads the retrodiction case a reason points at, if it
// points at one.
//
// The machine cannot judge prose, but it can refuse prose that points at
// nothing — which is what a typo in a case name produces.
func RetrodictionNamedBy(reason string) (string, bool) {
	rest, named := strings.CutPrefix(reason, retrodictionPrefix)
	if !named {
		return "", false
	}
	return strings.TrimSpace(rest), true
}

// SplitBackfill divides a selection into the checks redirected by the
// backfill list and the checks this run must prove.
//
// **named says the checks came from the command line**, and a named check is
// never redirected: backfill answers "the merge-base cannot prove this one",
// while naming a check with an explicit `--base` IS the run that proves it.
// Filtering those made the mechanism eat its own evidence — measured in
// review, the command `backfill.tsv` cites as where two checks were seen to
// fail redirected all seven and ran nothing.
func SplitBackfill(checks []string, entries map[string]string, named bool) (redirected, toProve []string) {
	for _, check := range checks {
		if _, listed := entries[check]; listed && !named {
			redirected = append(redirected, check)
			continue
		}
		toProve = append(toProve, check)
	}
	return redirected, toProve
}
