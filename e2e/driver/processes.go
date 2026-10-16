package driver

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

// PS answers the process-table questions through `pgrep`.
//
// **A pattern must be specific enough to be about this run.** The probe
// measured `pgrep -f wakil-ctx` matching children of three different
// worktrees' bundles on this machine, so a check asserting "nothing matching
// wakil-ctx survived" would fail on someone else's build. Checks pass a full
// bundle path; nothing here can enforce that, so it is said where the
// vocabulary is documented and again here.
type PS struct{}

// Matching returns "<pid> <command>" for every process whose full argv
// matches pattern.
//
// **Exit status 1 means no match and is not an error.** pgrep exits 1 when
// nothing matched, which is the commonest and most desirable outcome of an
// assertion that nothing survived; treating it as a failure would make every
// clean run red.
func (PS) Matching(pattern string) ([]string, error) {
	command := exec.Command("pgrep", "-fl", pattern)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()

	lines := splitNonEmpty(stdout.String())
	if err != nil {
		if exit, isExit := err.(*exec.ExitError); isExit && exit.ExitCode() == 1 && len(lines) == 0 {
			return nil, nil
		}
		return nil, fmt.Errorf("pgrep -fl %q: %w: %s", pattern, err, strings.TrimSpace(stderr.String()))
	}
	return lines, nil
}

func splitNonEmpty(output string) []string {
	var lines []string
	for _, line := range strings.Split(output, "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			lines = append(lines, trimmed)
		}
	}
	return lines
}
