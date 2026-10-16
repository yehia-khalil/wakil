package driver

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// liveWakils finds, in `ps -axo pid=,command=` output, every Wakil process
// that is not a staged fixture (#332): the operator's installed app, a branch
// build opened by hand, and the MCP shims either one spawns.
//
// **The staged-bundle guard cannot see these, by construction.** It finds
// other copies of `WakilE2E.app`; a live Wakil runs from `Wakil.app`, under a
// different bundle identifier (`dev.wakil.app`). Measured on 2026-09-30: one
// took the foreground mid-act and the scripted-agent check read as a window
// that never launched its agent; quit, the same suite passed 28/28.
func liveWakils(ps string) []int {
	const executable = "/Wakil.app/Contents/MacOS/Wakil"
	var pids []int
	for _, line := range strings.Split(ps, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || !strings.HasSuffix(fields[1], executable) ||
			strings.Contains(fields[1], "/"+StagedBundleName+"/") {
			continue
		}
		if pid, err := strconv.Atoi(fields[0]); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}

// liveWakilRefusal stops a launch while another Wakil is running. **A refusal
// rather than a warning**, for `refuseStrayFixtures`' reason: it can take the
// foreground at any moment, and a run made under that condition produces
// verdicts nobody can trust.
func liveWakilRefusal(pids []int) error {
	if len(pids) == 0 {
		return nil
	}
	return fmt.Errorf(
		"a Wakil that is not this run's fixture is running (pid %s) — the operator's app, a "+
			"build opened by hand, or a shim one of them spawned. It can take the foreground "+
			"mid-act and the keystrokes meant for the fixture go to it (#332). quit Wakil "+
			"(or `kill %s`) and retry",
		joinInts(pids), joinInts(pids))
}

func refuseLiveWakil() error {
	out, err := exec.Command("ps", "-axo", "pid=,command=").Output()
	if err != nil {
		return fmt.Errorf("ps: %w", err)
	}
	return liveWakilRefusal(liveWakils(string(out)))
}
