package driver

import (
	"strings"
	"testing"
	"time"
)

// #305: the failability column was read only from the current `make e2e-new`
// verdict, which lives in gitignored `.context/` and covers only the checks
// this branch touched. Re-rendered after a merge, every check the merged
// branch had proved red read "not new on this branch" — the proof gone.
// A proof is now committed beside the checks, one file per check.

func provedVerdict() Verdict {
	return Verdict{
		GeneratedAt: time.Date(2026, 9, 26, 10, 0, 0, 0, time.UTC),
		BaseCommit:  "753b6ff7a8ab0000",
		Checks: []CheckVerdict{
			{Name: "red.jsonl", File: "e2e/checks/seeded/red.jsonl", Red: true, Assertions: 3},
			{Name: "green.jsonl", File: "e2e/checks/seeded/green.jsonl", Red: false, Assertions: 3},
			{Name: "gone.jsonl", File: "e2e/checks/seeded/gone.jsonl", Missing: true},
			{Name: "empty.jsonl", File: "e2e/checks/seeded/empty.jsonl", Red: true},
			{Name: "back.jsonl", File: "e2e/checks/seeded/back.jsonl", Redirected: true, Reason: "elsewhere"},
		},
	}
}

func blobsOf(blobs map[string]string) func(string) (string, error) {
	return func(file string) (string, error) { return blobs[file], nil }
}

func TestOnlyACheckSeenToFailGetsAProof(t *testing.T) {
	repo := t.TempDir()
	if err := WriteProofs(repo, provedVerdict(), blobsOf(map[string]string{
		"e2e/checks/seeded/red.jsonl": "blob-red",
	})); err != nil {
		t.Fatal(err)
	}
	proofs, err := LoadProofs(repo)
	if err != nil {
		t.Fatal(err)
	}
	if len(proofs) != 1 {
		t.Fatalf("one check went red with assertions; got proofs for %v", proofs)
	}
	got := proofs["red.jsonl"]
	want := Proof{
		Check: "e2e/checks/seeded/red.jsonl", BaseCommit: "753b6ff7a8ab0000",
		ProvedAt: time.Date(2026, 9, 26, 10, 0, 0, 0, time.UTC), CheckBlob: "blob-red",
	}
	if got != want {
		t.Fatalf("proof = %+v, want %+v", got, want)
	}
}

func TestAnUnsoundRunWritesNoProof(t *testing.T) {
	repo := t.TempDir()
	verdict := provedVerdict()
	verdict.Fatal = []string{"a launch executed no check"}
	if err := WriteProofs(repo, verdict, blobsOf(nil)); err != nil {
		t.Fatal(err)
	}
	if proofs, _ := LoadProofs(repo); len(proofs) != 0 {
		t.Fatalf("a run that is not evidence must leave none: %v", proofs)
	}
}

func walkWithProof(proof Proof, currentBlob string) MachineWalk {
	walk := provenWalk()
	walk.Verdict.Checks = walk.Verdict.Checks[1:] // landing.jsonl is not new on this branch
	walk.Proofs = map[string]Proof{"landing.jsonl": proof}
	walk.Blobs = map[string]string{"e2e/checks/seeded/landing.jsonl": currentBlob}
	return walk
}

func TestAProofSurvivesTheMergeThatEndedItsBranch(t *testing.T) {
	walk := walkWithProof(Proof{
		Check: "e2e/checks/seeded/landing.jsonl", BaseCommit: "753b6ff7a8ab0000",
		ProvedAt: time.Date(2026, 9, 26, 10, 0, 0, 0, time.UTC), CheckBlob: "same",
	}, "same")
	md := walk.Markdown()
	if !strings.Contains(md, "✓ red vs 753b6ff7a8ab, recorded 2026-09-26") {
		t.Fatalf("the committed proof should be carried into the column:\n%s", md)
	}
	if strings.Contains(md, "not new on this branch") {
		t.Fatalf("a proved check must not read as unproved:\n%s", md)
	}
}

func TestAProofOfAnEarlierVersionSaysSo(t *testing.T) {
	walk := walkWithProof(Proof{
		Check: "e2e/checks/seeded/landing.jsonl", BaseCommit: "753b6ff7a8ab0000",
		ProvedAt: time.Date(2026, 9, 26, 10, 0, 0, 0, time.UTC), CheckBlob: "old",
	}, "new")
	if md := walk.Markdown(); !strings.Contains(md,
		"**proved red vs 753b6ff7a8ab on an earlier version — not re-proved**") {
		t.Fatalf("a check edited since its proof must not borrow it:\n%s", md)
	}
}

func TestACheckWithNoProofIsStillNotNewOnThisBranch(t *testing.T) {
	walk := provenWalk()
	walk.Verdict.Checks = walk.Verdict.Checks[1:]
	if md := walk.Markdown(); !strings.Contains(md, "not new on this branch") {
		t.Fatalf("with no proof the old wording stands:\n%s", md)
	}
}
