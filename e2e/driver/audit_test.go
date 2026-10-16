package driver

import (
	"path/filepath"
	"slices"
	"testing"
)

// TestTheCorpusIsEveryCheckAnyLaunchCanRun pins the coverage reader's corpus
// against the runner's own list of launches.
//
// **The two lists are one question asked twice.** `GroupChecks` decides which
// launch a check file belongs to and knows three directories; `CheckCorpus`
// decides which check files coverage is measured against and knew two. A check
// the runner runs but the auditor cannot see is worse than an uncovered one:
// the gate reports surface as untouched that a green check is exercising, so
// the one honest way to satisfy it is to write a second check for surface that
// already has one (#246). Read against the directories rather than a hardcoded
// count, so a fourth launch fails here rather than going quietly unmeasured.
func TestTheCorpusIsEveryCheckAnyLaunchCanRun(t *testing.T) {
	t.Chdir(repoRoot(t))

	var onDisk []string
	for _, dir := range []string{UnseededDir, SeededDir, AgentDir} {
		found, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
		if err != nil {
			t.Fatalf("globbing %s: %v", dir, err)
		}
		if len(found) == 0 {
			t.Fatalf("%s holds no check files, so this test would prove nothing", dir)
		}
		onDisk = append(onDisk, found...)
	}

	corpus := CheckCorpus()
	for _, check := range onDisk {
		if !slices.Contains(corpus, check) {
			t.Errorf("%s is a check on disk that the coverage audit never reads, so every "+
				"piece of surface it exercises is reported as untouched", check)
		}
	}

	// **And every path the corpus names has a launch to run it in.** The
	// converse failure — a corpus wider than the runner — would make the gate
	// measure coverage from files no run ever executes.
	if _, err := GroupChecks(corpus); err != nil {
		t.Errorf("the corpus names a path no launch will run: %v", err)
	}
}
