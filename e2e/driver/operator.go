package driver

import (
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// OperatorRoute is the harness's operator channel as the runner sees it: a Channel, and which
// actions it serves. `*OperatorChannel` is the live one.
type OperatorRoute interface {
	Channel
	Serves(action string) bool
}

// OperatorOnlyRefusal is the words of `ActionError.operatorOnly` (ActionRegistry.swift): what
// the registry tells an agent that asked for an operator-only action. A `dispatch` step that
// expects it is asserting about the agent, so it goes over the agent socket.
const OperatorOnlyRefusal = "only the operator can run this"

// OperatorSocketFor is the operator socket beside an agent socket — the app's
// `harnessSocketPath(forAgentSocket:)`: `<dir>/wakil-<id>.sock` gives `<dir>/<id>-e2e.sock`.
// Not a `wakil-*.sock`, so SocketsFor never offers it as an agent channel.
func OperatorSocketFor(agentSocket string) string {
	dir, name := filepath.Split(agentSocket)
	name = strings.TrimSuffix(name, ".sock")
	name = strings.TrimPrefix(name, "wakil-")
	return dir + name + "-e2e.sock"
}

// OperatorChannel is the operator channel: the socket only the staged e2e fixture opens, beside
// each agent socket, whose calls the app dispatches with a non-agent origin (`.debug`). It runs
// only the actions the agent may not, and it is never named in an agent's `--mcp-config`.
//
// **Found the way the agent socket is**: derived from the screen's agent socket and confirmed
// among what THIS pid holds (`lsof`), never by a directory scan — the reason is SocketsFor's.
// A switch moves the screen's agent socket, and with it this one.
type OperatorChannel struct {
	pid    int
	agent  operatorAgent
	held   func() ([]string, error)
	serves map[string]bool

	mu     sync.Mutex
	path   string
	client *MCP
}

// operatorAgent is what the operator channel needs of the screen's agent channel: its socket,
// which the operator socket sits beside, and what it says about the operator socket's start.
type operatorAgent interface {
	Socket() (string, error)
	HarnessFailure() (string, error)
}

// NewOperatorChannel opens the operator socket beside the screen's agent socket and reads which
// actions it serves. **Nil, with no error, when the pid holds none**: a build from before it —
// the merge-base `make e2e-new` drives — where every dispatch goes over the agent socket, as it
// did there. The app opens it before the agent socket it sits beside, so a current build that
// shows an agent socket already holds it.
//
// **An error when the agent socket says it failed to start** (`wakil/harnessFailure`): that is a
// current build whose channel is missing, and falling back would only move the failure to every
// operator-only step, worded as the agent's refusal.
func NewOperatorChannel(pid int, agent operatorAgent, held func() ([]string, error)) (*OperatorChannel, error) {
	channel := &OperatorChannel{pid: pid, agent: agent, held: held}
	path, err := channel.besideScreen()
	if err != nil {
		return nil, err
	}
	paths, err := held()
	if err != nil {
		return nil, err
	}
	if !contains(paths, path) {
		failure, err := agent.HarnessFailure()
		if err != nil {
			return nil, err
		}
		if failure != "" {
			return nil, fmt.Errorf("the operator channel failed to start: %s", failure)
		}
		return nil, nil
	}
	client, err := channel.clientFor(path)
	if err != nil {
		return nil, err
	}
	tools, err := client.Tools()
	if err != nil {
		return nil, fmt.Errorf("operator socket %s: %w", path, err)
	}
	channel.serves = map[string]bool{}
	for _, tool := range tools {
		channel.serves[tool.Name] = true
	}
	return channel, nil
}

// AwaitOperator is NewOperatorChannel for a live window: its sockets are what `lsof` says pid holds.
func AwaitOperator(pid int, agent *ScreenChannel) (*OperatorChannel, error) {
	return NewOperatorChannel(pid, agent, func() ([]string, error) { return UnixSocketsFor(pid) })
}

// Serves says whether the app advertises action on its operator socket.
func (c *OperatorChannel) Serves(action string) bool { return c.serves[action] }

// Actions is how many actions the operator socket serves.
func (c *OperatorChannel) Actions() int { return len(c.serves) }

// Call dispatches one action on the operator socket beside the screen's agent socket.
func (c *OperatorChannel) Call(action string, arguments map[string]interface{}) (ToolResult, error) {
	path, err := c.besideScreen()
	if err != nil {
		return ToolResult{}, err
	}
	client, err := c.clientFor(path)
	if err != nil {
		return ToolResult{}, err
	}
	return client.Call(action, arguments)
}

// Socket names the operator socket in hand.
func (c *OperatorChannel) Socket() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.path
}

// Close hangs up.
func (c *OperatorChannel) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	err := c.client.Close()
	c.client, c.path = nil, ""
	return err
}

func (c *OperatorChannel) besideScreen() (string, error) {
	agent, err := c.agent.Socket()
	if err != nil {
		return "", err
	}
	return OperatorSocketFor(agent), nil
}

// clientFor is the connection to path: the one in hand when it is still that socket, otherwise a
// new one, dialled only once the pid is seen to hold it.
func (c *OperatorChannel) clientFor(path string) (*MCP, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client != nil && c.path == path {
		return c.client, nil
	}
	if c.client != nil {
		_ = c.client.Close()
		c.client, c.path = nil, ""
	}
	paths, err := c.held()
	if err != nil {
		return nil, err
	}
	if !contains(paths, path) {
		return nil, fmt.Errorf(
			"pid %d holds no operator socket %s beside the screen's agent socket, so an "+
				"operator-only action has no channel (it is not sent to the agent socket instead)",
			c.pid, path)
	}
	client, err := DialMCPPath(path, 0)
	if err != nil {
		return nil, err
	}
	c.client, c.path = client, path
	return client, nil
}

func contains(paths []string, path string) bool {
	for _, p := range paths {
		if p == path {
			return true
		}
	}
	return false
}

// UnixSocketsFor is every named unix socket pid holds, whatever it is called (`lsof`, as SocketsFor).
func UnixSocketsFor(pid int) ([]string, error) {
	out, err := exec.Command("lsof", "-p", strconv.Itoa(pid), "-a", "-U", "-F", "n").Output()
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 1 {
			return nil, fmt.Errorf("lsof -p %d: %w", pid, err)
		}
	}
	return UnixSocketsFromLSOF(string(out)), nil
}

// UnixSocketsFromLSOF lists the named sockets in `lsof -F n` output, folded and sorted.
func UnixSocketsFromLSOF(output string) []string {
	seen := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		if path := strings.TrimPrefix(line, "n"); path != line && strings.HasPrefix(path, "/") {
			seen[path] = true
		}
	}
	paths := make([]string, 0, len(seen))
	for path := range seen {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths
}
