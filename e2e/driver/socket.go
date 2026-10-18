package driver

import (
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// SocketsFor returns every Wakil MCP socket that pid itself holds open.
//
// **It asks `lsof` for one known process, and never scans a directory.**
// `agentSocketPath` builds a socket's path from
// `FileManager.default.temporaryDirectory`, which does NOT honour an injected
// `TMPDIR` — Foundation always resolves the per-user Darwin directory via
// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, measured four ways in #248. So the
// fixture's sockets land in the same directory as the operator's, and
// distinguishing them by name or mtime is not possible in principle:
//
//   - **Nothing unlinks a socket at exit.** That directory held 69 `wakil-*.sock`
//     files dating to 2026-09-18 with exactly ONE live app, and 81 by the time
//     #249 was written. `MCPSocketServer.start` unlinks a stale file at its own
//     path, but that path carries a fresh session UUID every time, so it never
//     removes an earlier one. An mtime scan chooses from a pile of dead sockets.
//   - **A wrong choice is a WRITE to the operator's window.** This channel
//     dispatches actions. Picking the operator's socket would run them against
//     their live credentials, and nothing in the reply would say so — the same
//     silently-wrong-instance failure §6.4 measured for `--app dev.wakil.app`,
//     in the one channel where it does damage rather than returning the wrong
//     reading.
//
// `lsof -p <pid>` answers exactly, from a pid the runner already established by
// difference and already drives Orca with. **A window holds one socket per
// place it has shown** (`WindowModel.openShownSocket`, background agents 3 of
// 4), each pinned to its place: which of them to drive is SelectScreenSocket's
// question, not this one's.
func SocketsFor(pid int) ([]string, error) {
	command := exec.Command("lsof", "-p", strconv.Itoa(pid), "-a", "-U", "-F", "n")
	out, err := command.Output()
	if err != nil {
		var exit *exec.ExitError
		// lsof exits 1 when the process holds nothing matching, which is an
		// answer — the window has not shown a place yet.
		if !errors.As(err, &exit) || exit.ExitCode() != 1 {
			return nil, fmt.Errorf("lsof -p %d: %w", pid, err)
		}
	}
	return SocketsFromLSOF(pid, string(out))
}

// SocketsFromLSOF lists the Wakil sockets in `lsof -F n` output, sorted.
//
// A listening socket shows up on several descriptors at the same path, so
// duplicates are folded. None is a refusal: there is nothing to dispatch into.
func SocketsFromLSOF(pid int, output string) ([]string, error) {
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
	if len(paths) == 0 {
		return nil, fmt.Errorf(
			"pid %d holds no wakil-*.sock. The window opens one for each place it shows, at "+
				"launch and on every switch, so either it has not shown one yet or this pid is "+
				"not a Wakil window", pid)
	}
	return paths, nil
}

func isWakilSocket(path string) bool {
	slash := strings.LastIndex(path, "/")
	name := path[slash+1:]
	return strings.HasPrefix(name, "wakil-") && strings.HasSuffix(name, ".sock")
}

// Place is an (organisation, project registry key, environment), as a socket's
// `initialize` reports it (`initializeMeta` in MCPServer.swift).
type Place struct {
	Organization string `json:"organization"`
	Project      string `json:"project"`
	Environment  string `json:"environment"`
}

func (p Place) String() string {
	return fmt.Sprintf("%q/%q/%q", p.Organization, p.Project, p.Environment)
}

// SocketPlace is what one socket said about itself when asked: the place
// every call on it is made for, and the place the window showed as it
// answered. Screen is nil when the window did not say.
type SocketPlace struct {
	Path   string
	Place  Place
	Screen *Place
	// Unplaced marks a socket that says nothing about places at all
	// (ErrNoPlaceMeta): the window-wide socket of a Wakil built before the
	// shown-place sockets, which `make e2e-new` drives as the merge-base.
	Unplaced bool
}

// SelectScreenSocket picks, of a window's sockets, the one pinned to the
// place on screen: the channel an operator's agent in that place would speak.
//
// **Both answers come from the window**, through the socket's own
// `initialize`. The screen is not read from `active.json`: that file holds the
// project's path rather than its registry key, is one file per organisation,
// and names no organisation at all — after an org switch nothing on disk says
// which one the window shows.
//
// **The refusal to guess is kept.** No match, several, or sockets that
// disagree about the screen (a switch landed between two answers) is an
// error naming every socket and what it said: this channel dispatches
// actions, and the wrong socket runs them in another place.
func SelectScreenSocket(pid int, probes []SocketPlace) (string, error) {
	if len(probes) == 0 {
		return "", fmt.Errorf("pid %d holds no wakil-*.sock to choose from", pid)
	}
	// **A build from before the shown-place sockets has one socket, and it
	// follows the screen** — the window-wide socket every call went through.
	// Driving it is not a guess, and it is what a red-required run against a
	// merge-base that predates them must do; two, or one beside placed ones,
	// is not that build and stays refused.
	unplaced := 0
	for _, probe := range probes {
		if probe.Unplaced {
			unplaced++
		}
	}
	if unplaced > 0 {
		if unplaced == 1 && len(probes) == 1 {
			return probes[0].Path, nil
		}
		return "", fmt.Errorf(
			"pid %d: %d of its %d sockets say nothing about places — neither a build from "+
				"before the shown-place sockets (one socket) nor one after (%s)",
			pid, unplaced, len(probes), describeProbes(probes))
	}
	var screen *Place
	for _, probe := range probes {
		if probe.Screen == nil {
			return "", fmt.Errorf(
				"pid %d: %s does not say which place the window shows, so no socket can be "+
					"chosen by it — a Wakil built before the shown-place sockets (%s)",
				pid, probe.Path, describeProbes(probes))
		}
		if screen != nil && *screen != *probe.Screen {
			return "", fmt.Errorf(
				"pid %d: its sockets disagree about the place on screen, so a switch landed "+
					"between their answers (%s)", pid, describeProbes(probes))
		}
		screen = probe.Screen
	}
	var matches []string
	for _, probe := range probes {
		if probe.Place == *screen {
			matches = append(matches, probe.Path)
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return "", fmt.Errorf(
			"pid %d shows %s and holds no socket pinned to it (%s) — the window opens one "+
				"when a place is shown, so it has not got there yet",
			pid, screen, describeProbes(probes))
	default:
		return "", fmt.Errorf(
			"pid %d holds %d sockets pinned to %s, the place on screen (%s) — the runner "+
				"cannot tell which session it would be writing into, and must not guess in a "+
				"channel that dispatches actions",
			pid, len(matches), screen, describeProbes(probes))
	}
}

func describeProbes(probes []SocketPlace) string {
	parts := make([]string, 0, len(probes))
	for _, probe := range probes {
		screen := "unknown"
		if probe.Screen != nil {
			screen = probe.Screen.String()
		}
		parts = append(parts, fmt.Sprintf("%s: pinned to %s, screen %s", probe.Path, probe.Place, screen))
	}
	return strings.Join(parts, "; ")
}
