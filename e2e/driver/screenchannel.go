package driver

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// ScreenChannel is the agent channel of the place the window shows: the
// socket an agent working there would speak on, re-chosen whenever the screen
// moves.
//
// **Why it moves.** A window holds one socket per place it has shown, each
// pinned for life to its own place and session (`WindowModel.openShownSocket`)
// — never one that follows the screen. A check that switches organisation,
// project or environment and then dispatches means the place it switched to,
// so the dispatch must reach THAT place's socket; the one it started on still
// answers, for the place it was opened in.
//
// **Checked before every call, cheaply.** The socket in hand is asked, on its
// own connection, whether its place — and conversation — is still the one on
// screen (`MCP.Probe`); only when it is not — or it has gone — are the pid's sockets
// listed again and each asked (SelectScreenSocket). A switch the window is
// still landing is waited for, up to `within`; past that the refusal names
// every socket and what it said.
type ScreenChannel struct {
	pid     int
	within  time.Duration
	sockets func() ([]string, error)

	mu     sync.Mutex
	path   string
	client *MCP
}

// NewScreenChannel builds the channel for pid, listing its sockets with
// `sockets` — `SocketsFor(pid)` for a live window, a stand-in in tests. Nothing
// is dialled until the first use.
func NewScreenChannel(pid int, within time.Duration, sockets func() ([]string, error)) *ScreenChannel {
	return &ScreenChannel{pid: pid, within: within, sockets: sockets}
}

// Call dispatches one action on the socket of the place on screen.
func (c *ScreenChannel) Call(action string, arguments map[string]interface{}) (ToolResult, error) {
	client, err := c.screenClient()
	if err != nil {
		return ToolResult{}, err
	}
	return client.Call(action, arguments)
}

// Initialize performs the handshake on the socket of the place on screen.
func (c *ScreenChannel) Initialize() (string, error) {
	client, err := c.screenClient()
	if err != nil {
		return "", err
	}
	return client.Initialize()
}

// Tools lists the actions on the socket of the place on screen.
func (c *ScreenChannel) Tools() ([]Tool, error) {
	client, err := c.screenClient()
	if err != nil {
		return nil, err
	}
	return client.Tools()
}

// Socket names the socket of the place on screen.
func (c *ScreenChannel) Socket() (string, error) {
	if _, err := c.screenClient(); err != nil {
		return "", err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.path, nil
}

// Close hangs up.
func (c *ScreenChannel) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	err := c.client.Close()
	c.client, c.path = nil, ""
	return err
}

// screenClient is the connection to the socket pinned to the place on screen:
// the one in hand while its place is still the screen's, otherwise a fresh
// choice among the pid's sockets.
func (c *ScreenChannel) screenClient() (*MCP, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client != nil {
		probe, err := c.client.Probe()
		if err == nil && probe.isScreens() {
			return c.client, nil
		}
		// The one socket of a build from before the shown-place sockets: it
		// follows the screen, so it is still the screen's (SelectScreenSocket).
		if errors.Is(err, ErrNoPlaceMeta) {
			return c.client, nil
		}
		_ = c.client.Close()
		c.client, c.path = nil, ""
	}
	deadline := time.Now().Add(c.within)
	var last error
	for {
		path, err := c.choose()
		if err == nil {
			var client *MCP
			client, err = DialMCPPath(path, 0)
			if err == nil {
				c.client, c.path = client, path
				return client, nil
			}
		}
		last = err
		if !time.Now().Before(deadline) {
			return nil, fmt.Errorf("pid %d: no socket for the place on screen within %s: %w", c.pid, c.within, last)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// choose asks every socket the pid holds which place it is pinned to and
// which the window shows, and picks the one whose place is the screen's.
func (c *ScreenChannel) choose() (string, error) {
	paths, err := c.sockets()
	if err != nil {
		return "", err
	}
	probes := make([]SocketPlace, 0, len(paths))
	for _, path := range paths {
		probe, err := probeSocket(path)
		if err != nil {
			return "", err
		}
		probes = append(probes, probe)
	}
	return SelectScreenSocket(c.pid, probes)
}

// probeSocket asks one socket what it is pinned to, on a connection of its own.
func probeSocket(path string) (SocketPlace, error) {
	client, err := DialMCPPath(path, 5*time.Second)
	if err != nil {
		return SocketPlace{}, err
	}
	defer client.Close()
	probe, err := client.Probe()
	if errors.Is(err, ErrNoPlaceMeta) {
		return SocketPlace{Path: path, Unplaced: true}, nil
	}
	if err != nil {
		return SocketPlace{}, fmt.Errorf("%s: %w", path, err)
	}
	probe.Path = path
	return probe, nil
}
