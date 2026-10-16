package driver

import (
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// SocketFor returns the MCP socket that pid itself holds open.
//
// **It asks `lsof` for one known process, and never scans a directory.**
// `WindowSession.start` builds its socket path from
// `FileManager.default.temporaryDirectory`, which does NOT honour an injected
// `TMPDIR` — Foundation always resolves the per-user Darwin directory via
// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, measured four ways in #248. So the
// fixture's socket lands in the same directory as the operator's, and
// distinguishing them by name or mtime is not possible in principle:
//
//   - **Nothing unlinks a socket at exit.** That directory held 69 `wakil-*.sock`
//     files dating to 2026-09-18 with exactly ONE live app, and 81 by the time
//     #249 was written. `MCPSocketServer.start` unlinks a stale file at its own
//     path, but that path carries a fresh session UUID every launch, so it never
//     removes an earlier one. An mtime scan chooses from a pile of dead sockets.
//   - **A wrong choice is a WRITE to the operator's window.** This channel
//     dispatches actions. Picking the operator's socket would run them against
//     their live credentials, and nothing in the reply would say so — the same
//     silently-wrong-instance failure §6.4 measured for `--app dev.wakil.app`,
//     in the one channel where it does damage rather than returning the wrong
//     reading.
//
// `lsof -p <pid>` answers exactly, from a pid the runner already established by
// difference and already drives Orca with.
func SocketFor(pid int) (string, error) {
	command := exec.Command("lsof", "-p", strconv.Itoa(pid), "-a", "-U", "-F", "n")
	out, err := command.Output()
	if err != nil {
		var exit *exec.ExitError
		// lsof exits 1 when the process holds nothing matching, which is an
		// answer — the session has not opened its socket yet.
		if !errors.As(err, &exit) || exit.ExitCode() != 1 {
			return "", fmt.Errorf("lsof -p %d: %w", pid, err)
		}
	}
	return SocketFromLSOF(pid, string(out))
}

// SocketFromLSOF picks the one Wakil socket out of `lsof -F n` output.
//
// A listening socket shows up on several descriptors at the same path, so
// duplicates are folded. Two DIFFERENT paths are a refusal: one process should
// hold one session's socket, and an instance the runner cannot pin down is one
// it must not dispatch writes into.
func SocketFromLSOF(pid int, output string) (string, error) {
	seen := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		if !strings.HasPrefix(line, "n") {
			continue
		}
		path := strings.TrimPrefix(line, "n")
		// `->0x…` is lsof's spelling for a connected socket with no path on
		// this side. Only a bound, named socket is addressable.
		if !strings.HasPrefix(path, "/") || !isWakilSocket(path) {
			continue
		}
		seen[path] = true
	}
	paths := make([]string, 0, len(seen))
	for path := range seen {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	switch len(paths) {
	case 1:
		return paths[0], nil
	case 0:
		return "", fmt.Errorf(
			"pid %d holds no wakil-*.sock. `WindowSession.start` opens one when the window "+
				"starts its session, so either it has not got there yet or this pid is not a "+
				"Wakil window", pid)
	default:
		return "", fmt.Errorf(
			"pid %d holds %d wakil sockets (%s) — the runner cannot tell which session it "+
				"would be writing into, and must not guess in a channel that dispatches actions",
			pid, len(paths), strings.Join(paths, ", "))
	}
}

func isWakilSocket(path string) bool {
	slash := strings.LastIndex(path, "/")
	name := path[slash+1:]
	return strings.HasPrefix(name, "wakil-") && strings.HasSuffix(name, ".sock")
}
