package driver

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// NewPID returns the single process that appeared between two samples.
//
// **Why the runner may not simply ask for "the Wakil process".** With two
// instances running, `list-windows --app dev.wakil.app` returned only the
// operator's window, with no error and no indication a second existed
// (docs/wakil/agent-e2e-probe.md §1). Bundle-id addressing fails silently and
// in the dangerous direction: a check that reached the operator's window would
// be driving their live credentials. So the runner establishes its own pid by
// difference and addresses it as `pid:<n>` from then on.
//
// Zero or several new processes are both refusals rather than guesses. An
// instance the runner cannot identify is one it must not drive, and it is also
// one it cannot reliably kill afterwards.
//
// Processes that disappeared between the samples are ignored: the operator
// closing an unrelated window mid-launch is not this run's business.
func NewPID(before, after []int) (int, error) {
	existing := make(map[int]bool, len(before))
	for _, pid := range before {
		existing[pid] = true
	}
	var appeared []int
	for _, pid := range after {
		if !existing[pid] {
			appeared = append(appeared, pid)
		}
	}
	sort.Ints(appeared)

	switch len(appeared) {
	case 1:
		return appeared[0], nil
	case 0:
		return 0, fmt.Errorf(
			"the launch produced no new process — the bundle may have failed to start, " +
				"or it was started as a backgrounded child of a shell, which dies with that " +
				"shell and then reads as `app_not_found`; use `open -n`")
	default:
		return 0, fmt.Errorf(
			"the launch produced %d new processes (%s) — the runner cannot tell which "+
				"instance is its own, and must not drive one it cannot identify; close the "+
				"strays and retry",
			len(appeared), joinInts(appeared))
	}
}

func joinInts(values []int) string {
	parts := make([]string, len(values))
	for i, value := range values {
		parts[i] = strconv.Itoa(value)
	}
	return strings.Join(parts, ", ")
}
