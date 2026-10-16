package driver

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// **Backfill is the case §8 did not cover, and this branch is the specimen.**
// `make e2e-new` proves a branch's new checks failable against the merge-base,
// on the premise that a check accompanies the work it tests. 2c-iii's seven
// check surface that shipped on 2026-09-18, five days before this branch
// forked — so all seven PASS against the merge-base, and the target correctly
// refuses them. The premise, not the target, is what does not apply.
//
// A backfill entry is not an exemption from being seen to fail. It is a
// redirect: it says where the check WAS seen to fail, it is printed on every
// run, and a reviewer reads the reason. The machine cannot judge prose and
// does not pretend to.
func TestBackfillRedirectsACheckRatherThanExemptingIt(t *testing.T) {
	entries, err := LoadBackfill(backfillFixture(t,
		"e2e/checks/seeded/a.jsonl\tmake e2e-retrodict: 1-profile-never-sourced\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("got %v", entries)
	}
	if entries["e2e/checks/seeded/a.jsonl"] == "" {
		t.Fatalf("the reason must be carried, got %v", entries)
	}
}

// **An entry with no reason is refused.** A bare list of exempt checks is a
// list of checks nobody has to justify, and it grows.
func TestLoadBackfillRefusesAnEntryWithNoReason(t *testing.T) {
	_, err := LoadBackfill(backfillFixture(t, "e2e/checks/seeded/a.jsonl\n"))
	if err == nil {
		t.Fatal("want a refusal: no reason given")
	}
	if !strings.Contains(err.Error(), "reason") {
		t.Fatalf("got %q", err)
	}
}

func TestLoadBackfillSkipsCommentsAndBlankLines(t *testing.T) {
	entries, err := LoadBackfill(backfillFixture(t,
		"# why this file exists\n\ne2e/checks/seeded/a.jsonl\tproved by X\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("got %v", entries)
	}
}

// A file that is not there is not an error: most branches have none, and
// requiring one would make the ordinary case carry a file full of nothing.
func TestLoadBackfillIsEmptyWhenThereIsNoFile(t *testing.T) {
	entries, err := LoadBackfill(filepath.Join(t.TempDir(), "absent"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("got %v", entries)
	}
}

// THE LIVE FILE. Every entry must name a check that exists — a stale entry
// silently exempts nothing and hides that the check it meant is gone.
func TestTheRepositorysBackfillEntriesAllNameChecksThatExist(t *testing.T) {
	entries, err := LoadBackfill("../../" + BackfillFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for check := range entries {
		if _, err := os.Stat("../../" + check); err != nil {
			t.Errorf("backfill names %s, which is not there: %v", check, err)
		}
	}
}

// **A reason naming a retrodiction case must name one that exists.** The
// machine cannot judge whether a reason is a good reason; it can refuse a
// reason that points at nothing, which is the failure a typo produces.
func TestTheRepositorysBackfillReasonsPointAtRealRetrodictions(t *testing.T) {
	entries, err := LoadBackfill("../../" + BackfillFile)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(Retrodictions))
	for _, retrodiction := range Retrodictions {
		names = append(names, retrodiction.Name)
	}
	for check, reason := range entries {
		named, isRetrodiction := RetrodictionNamedBy(reason)
		if !isRetrodiction {
			continue
		}
		if !slices.Contains(names, named) {
			t.Errorf("%s: its reason names retrodiction %q, which does not exist", check, named)
		}
	}
}

func backfillFixture(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "backfill.tsv")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// **A check named on the command line is never redirected.** Backfill answers
// "the merge-base cannot prove this one"; naming a check explicitly, with an
// explicit `--base`, IS the run that proves it.
//
// Found in review, and it was circular: with all seven listed, the very
// command `backfill.tsv` cites as where checks 2 and 4 were seen to fail
// redirected all seven and ran nothing — so those two entries pointed at
// evidence the mechanism itself had made unreproducible.
func TestSplitBackfillNeverRedirectsACheckNamedOnTheCommandLine(t *testing.T) {
	entries := map[string]string{"e2e/checks/seeded/a.jsonl": "proved by X"}
	redirected, toProve := SplitBackfill([]string{"e2e/checks/seeded/a.jsonl"}, entries, true)
	if len(redirected) != 0 {
		t.Fatalf("a named check must not be redirected, got %v", redirected)
	}
	if len(toProve) != 1 {
		t.Fatalf("a named check must be proved, got %v", toProve)
	}
}

// A diff-derived selection is redirected as usual — that is the case the
// mechanism exists for.
func TestSplitBackfillRedirectsADiffDerivedCheck(t *testing.T) {
	entries := map[string]string{"e2e/checks/seeded/a.jsonl": "proved by X"}
	redirected, toProve := SplitBackfill(
		[]string{"e2e/checks/seeded/a.jsonl", "e2e/checks/seeded/b.jsonl"}, entries, false)
	if len(redirected) != 1 || redirected[0] != "e2e/checks/seeded/a.jsonl" {
		t.Fatalf("got %v", redirected)
	}
	if len(toProve) != 1 || toProve[0] != "e2e/checks/seeded/b.jsonl" {
		t.Fatalf("got %v", toProve)
	}
}

// **A redirect is recorded, not only printed.** The verdict is what the Cover
// rung reads without being told where to look, and a redirect that lived only
// in stdout left verdict.json claiming the branch had no checks at all
// whenever some were redirected and others proved.
func TestVerdictRecordsARedirect(t *testing.T) {
	verdict := Verdict{}
	verdict.AddRedirect("e2e/checks/seeded/a.jsonl", "make e2e-retrodict: 1-profile-never-sourced")
	if len(verdict.Checks) != 1 {
		t.Fatalf("got %v", verdict.Checks)
	}
	recorded := verdict.Checks[0]
	if !recorded.Redirected || recorded.Reason == "" {
		t.Fatalf("want a redirected row carrying its reason, got %+v", recorded)
	}
	if recorded.Red {
		t.Fatal("a redirected check was not proved red HERE, and must not read as if it were")
	}
	// It is not a failure of this run: the check names where it WAS seen to
	// fail, and a reviewer reads that.
	if err := verdict.Err(); err != nil {
		t.Fatalf("a redirect does not fail the target: %v", err)
	}
	if verdict.Proved() {
		t.Fatal("a run that only redirected has proved nothing itself")
	}
}
