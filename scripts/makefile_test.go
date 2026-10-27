package scripts

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The Makefile is the second non-Go artefact this package covers (see the
// package doc). It is here rather than at the repository root because a
// Go test needs a package to live in, and this one already exists for
// exactly this purpose: making `go test ./...` cover the parts of the
// build that are not Go source.

// repoRoot returns the repository root, which is this package's parent.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "Makefile")); err != nil {
		t.Fatalf("no Makefile at %s: %v", root, err)
	}
	return root
}

// recipeEnv runs a throwaway target in the REAL Makefile's context and
// returns the value name has in the environment a recipe actually sees.
//
// The technique is `make -f Makefile -f <probe.mk> <probe-target>`: GNU
// make reads both files, so every variable, export and conditional in the
// real Makefile is in force, and the probe target's recipe runs in exactly
// the environment `build`, `test` and `vet` run in. That is what makes
// this a behavioural check rather than a grep — it observes the exported
// environment, which is the thing that actually matters, instead of
// pattern-matching the text that is supposed to produce it.
//
// `make -p` was tried first and rejected: the make bundled with macOS is
// GNU Make 3.81, and its database dump prints the assignment
// ("CGO_ENABLED := 0") identically whether or not the variable is
// exported, so it cannot tell the two apart. This can.
func recipeEnv(t *testing.T, name string) string {
	t.Helper()
	makeBin, err := exec.LookPath("make")
	if err != nil {
		t.Skipf("make is not on PATH, so the Makefile's behaviour cannot be observed: %v", err)
	}
	root := repoRoot(t)

	probe := filepath.Join(t.TempDir(), "probe.mk")
	body := "wakil-probe-recipe-env:\n\t@printf '%s' \"$$" + name + "\"\n"
	if err := os.WriteFile(probe, []byte(body), 0o644); err != nil {
		t.Fatalf("write probe makefile: %v", err)
	}

	cmd := exec.Command(makeBin, "-C", root, "-f", "Makefile", "-f", probe, "wakil-probe-recipe-env")
	// The variable must be UNSET in the environment make inherits, and
	// unset is not the same as set-to-empty here. Measured with GNU Make
	// 3.81 against a Makefile whose `export` keyword had been removed:
	//
	//	env -u CGO_ENABLED make ...   -> recipe sees ""   (mutant caught)
	//	CGO_ENABLED=  make ...        -> recipe sees "0"  (mutant MISSED)
	//	CGO_ENABLED=1 make ...        -> recipe sees "0"  (mutant MISSED)
	//
	// make re-exports any variable that ORIGINATED in its environment,
	// carrying whatever value the makefile later assigned it. So merely
	// blanking the variable hands the un-exported mutant a free pass: the
	// value is correct, but only because the test itself put the name in
	// the environment. Removing the entry entirely is the only condition
	// under which a missing `export` is observable at all.
	cmd.Env = withoutEnv(os.Environ(), name)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("make probe failed: %v (output %q)", err, out)
	}
	return string(out)
}

// withoutEnv returns env with every "name=..." entry removed.
func withoutEnv(env []string, name string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if !strings.HasPrefix(kv, name+"=") {
			out = append(out, kv)
		}
	}
	return out
}

// TestMakefileExportsCgoDisabledToEveryRecipe pins the fix for the
// inconsistency the final review found: CGO_ENABLED=0 was set inline on
// the `build` recipe only, so `make test` and `make vet` ran with the
// toolchain default (CGO_ENABLED=1 here) and certified a configuration
// nothing shipped.
//
// It is pinned behaviourally because the failure mode is silent in both
// directions. Nothing about a cgo-on test run looks different — the suite
// passes either way, as the Makefile's comment records — so without this
// there is no signal at all if the `export` is dropped or a target grows
// its own inline override.
//
// The mutation this kills: removing the `export` keyword, which leaves the
// variable set for make's own expansion but absent from every recipe's
// environment.
func TestMakefileExportsCgoDisabledToEveryRecipe(t *testing.T) {
	if got := recipeEnv(t, "CGO_ENABLED"); got != "0" {
		t.Fatalf("a Makefile recipe sees CGO_ENABLED=%q, want \"0\" — `make test` and `make vet` are no longer compiling under the same constraint as `make build`", got)
	}
}

// TestMakefileTargetsDoNotOverrideCgo guards the other half: a recipe that
// sets CGO_ENABLED for itself would defeat the single exported value
// without disturbing the probe above, since the probe runs its own target.
//
// This one IS a text scan, and deliberately narrow — it looks only for an
// assignment to this one variable inside the file. A behavioural version
// would have to run every target, which for `build` and `test` means
// minutes of work to detect a one-line mistake.
func TestMakefileTargetsDoNotOverrideCgo(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(repoRoot(t), "Makefile"))
	if err != nil {
		t.Fatalf("read Makefile: %v", err)
	}
	assignments := 0
	for i, line := range strings.Split(string(b), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") || !strings.Contains(line, "CGO_ENABLED") {
			continue
		}
		if !strings.Contains(line, "CGO_ENABLED=") && !strings.Contains(line, "CGO_ENABLED :=") {
			continue
		}
		assignments++
		if trimmed != "export CGO_ENABLED := 0" {
			t.Errorf("Makefile line %d assigns CGO_ENABLED outside the single exported definition: %q", i+1, trimmed)
		}
	}
	if assignments != 1 {
		t.Errorf("found %d CGO_ENABLED assignments in the Makefile, want exactly 1 (the exported one)", assignments)
	}
}

// e2eRunWith runs the shared `e2e-run` loop over two check files with a stub
// runner that logs each file it is handed and goes red, and returns the files
// the loop reached and whether make exited non-zero.
func e2eRunWith(t *testing.T, extra ...string) ([]string, bool) {
	t.Helper()
	makeBin, err := exec.LookPath("make")
	if err != nil {
		t.Skipf("make is not on PATH: %v", err)
	}
	dir := t.TempDir()
	log := filepath.Join(dir, "ran.log")
	runner := filepath.Join(dir, "runner.sh")
	body := "#!/bin/sh\nfor last; do :; done\necho \"$last\" >> " + log + "\nexit 1\n"
	if err := os.WriteFile(runner, []byte(body), 0o755); err != nil {
		t.Fatalf("write runner: %v", err)
	}
	args := append([]string{"-C", repoRoot(t), "--no-print-directory", "e2e-run",
		"E2E_BUNDLE=" + dir, "E2E_FILES=a.jsonl b.jsonl", "E2E_RUNNER=" + runner}, extra...)
	runErr := exec.Command(makeBin, args...).Run()
	ran, _ := os.ReadFile(log)
	return strings.Fields(string(ran)), runErr != nil
}

func TestE2ERunStopsAtTheFirstRedFileByDefault(t *testing.T) {
	ran, failed := e2eRunWith(t)
	if strings.Join(ran, " ") != "a.jsonl" || !failed {
		t.Fatalf("ran %v, failed %v; want only a.jsonl and a red exit", ran, failed)
	}
}

func TestE2ERunKeepsGoingWhenAsked(t *testing.T) {
	ran, failed := e2eRunWith(t, "E2E_KEEP_GOING=1")
	if strings.Join(ran, " ") != "a.jsonl b.jsonl" || !failed {
		t.Fatalf("ran %v, failed %v; want a.jsonl then b.jsonl and a red exit", ran, failed)
	}
}
