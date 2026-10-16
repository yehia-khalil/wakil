package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ProofDir holds one committed proof per check that `make e2e-new` saw fail
// against the merge-base (#305).
//
// **Committed, not in `.context/`.** The verdict there is gitignored, belongs
// to one worktree, and covers only the checks the current branch touched. A
// runbook re-rendered after a merge — or in any other worktree — read every
// check the merged branch had proved as "not new on this branch", and the
// evidence the Cover rung rests on was gone. A file per check, so two
// branches proving different checks never touch the same file.
const ProofDir = "e2e/checks/proofs"

// Proof is that a check, as it stood (CheckBlob, its `git hash-object`), went
// red against BaseCommit at ProvedAt.
type Proof struct {
	Check      string    `json:"check"`
	BaseCommit string    `json:"baseCommit"`
	ProvedAt   time.Time `json:"provedAt"`
	CheckBlob  string    `json:"checkBlob"`
}

// WriteProofs records a proof for every check the verdict saw go red with
// assertions behind it. A redirected, missing or green check proves nothing
// here, and a run with a Fatal fault proves nothing at all. A newer proof of
// the same check replaces the older one.
func WriteProofs(repo string, verdict Verdict, blobOf func(file string) (string, error)) error {
	if len(verdict.Fatal) > 0 {
		return nil
	}
	dir := filepath.Join(repo, ProofDir)
	for _, check := range verdict.Checks {
		if !check.Red || check.Redirected || check.Missing || check.Assertions == 0 {
			continue
		}
		blob, err := blobOf(check.File)
		if err != nil {
			return fmt.Errorf("hashing %s for its proof: %w", check.File, err)
		}
		proof := Proof{
			Check: filepath.Clean(check.File), BaseCommit: verdict.BaseCommit,
			ProvedAt: verdict.GeneratedAt.UTC(), CheckBlob: blob,
		}
		data, err := json.MarshalIndent(proof, "", "  ")
		if err != nil {
			return err
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		path := filepath.Join(dir, strings.TrimSuffix(filepath.Base(check.File), ".jsonl")+".json")
		if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// LoadProofs reads every proof, keyed by the check's base name — the key the
// whole harness already uses (`sameCheckFile`). No directory is no proofs.
func LoadProofs(repo string) (map[string]Proof, error) {
	entries, err := os.ReadDir(filepath.Join(repo, ProofDir))
	if os.IsNotExist(err) {
		return map[string]Proof{}, nil
	}
	if err != nil {
		return nil, err
	}
	proofs := map[string]Proof{}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(repo, ProofDir, entry.Name()))
		if err != nil {
			return nil, err
		}
		var proof Proof
		if err := json.Unmarshal(data, &proof); err != nil {
			return nil, fmt.Errorf("%s: %w", entry.Name(), err)
		}
		proofs[filepath.Base(proof.Check)] = proof
	}
	return proofs, nil
}

// GitBlob is a check file's `git hash-object` — what a proof records, and
// what the renderer compares it against.
func GitBlob(repo string) func(file string) (string, error) {
	return func(file string) (string, error) {
		out, err := exec.Command("git", "-C", repo, "hash-object", "--", file).Output()
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(out)), nil
	}
}
