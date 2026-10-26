package driver

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

// MCP is a client on one instance's live MCP socket: the channel that answers
// *what does the app believe*, and the second way to drive it.
//
// **The harness does not build an observation surface; it connects to one.**
// The window opens an `MCPSocketServer` with `PaneSnapshotJSON` behind it for
// each place it shows, and that is Invariant 3's channel — the same one a real
// agent in that place speaks (ScreenChannel picks which). Reading through it means a check sees exactly what
// the agent would, rather than a second rendering of the same state.
//
// **The division of labour, settled by the probe.** The accessibility tree
// answers *is it present, is it labelled, is it selected*; `read_pane` answers
// *what does it contain*. A data-surface row is ONE tree element labelled
// "id: 1, name: widgets" and its cells are deliberately hidden
// (`DataSurface.swift`, `.accessibilityElement(children: .ignore)`), because a
// Grid of Text views gave VoiceOver nothing. So a check asserting on a
// particular cell must come through here and cannot go through the tree.
type MCP struct {
	conn    net.Conn
	reader  *bufio.Reader
	mu      sync.Mutex
	nextID  int
	timeout time.Duration
}

// DialMCPPath connects to a socket by path: one ScreenChannel chose, or a
// test's stand-in server.
func DialMCPPath(path string, timeout time.Duration) (*MCP, error) {
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, fmt.Errorf("connecting to %s: %w", path, err)
	}
	return &MCP{conn: conn, reader: bufio.NewReader(conn), timeout: timeout}, nil
}

// Close hangs up.
func (m *MCP) Close() error {
	if m == nil || m.conn == nil {
		return nil
	}
	return m.conn.Close()
}

// AwaitMCP waits for pid to open the socket of the place it shows, and
// returns the channel pinned to whatever place it shows from then on.
//
// **A predicate with a deadline, never a fixed sleep.** The socket appears
// once the window has read its context and shown its place, which is not at
// launch and not at a time anything here can know.
func AwaitMCP(pid int, within time.Duration) (*ScreenChannel, error) {
	channel := NewScreenChannel(pid, within, func() ([]string, error) { return SocketsFor(pid) })
	if _, err := channel.Socket(); err != nil {
		return nil, fmt.Errorf("pid %d opened no usable MCP socket within %s: %w", pid, within, err)
	}
	return channel, nil
}

type rpcRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return fmt.Sprintf("%d: %s", e.Code, e.Message) }

type rpcReply struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

// Do sends one request and returns its result.
//
// The wire is newline-delimited JSON — `encodeFrame` appends a single "\n" —
// so a frame is one line and `bufio.Reader.ReadBytes` is the whole reassembly.
//
// **A reply for a different id is a failure, not something to skip past.** The
// server answers in order on one connection, so a mismatch means the stream is
// out of step, and a client that hunted for "its" reply would hide that while
// silently attributing one call's answer to another.
func (m *MCP) Do(method string, params interface{}) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.nextID++
	id := m.nextID
	frame, err := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params})
	if err != nil {
		return nil, err
	}
	if err := m.conn.SetDeadline(time.Now().Add(m.timeout)); err != nil {
		return nil, err
	}
	if _, err := m.conn.Write(append(frame, '\n')); err != nil {
		return nil, fmt.Errorf("%s: writing the request: %w", method, err)
	}
	line, err := m.reader.ReadBytes('\n')
	if err != nil {
		return nil, fmt.Errorf("%s: reading the reply: %w", method, err)
	}
	var reply rpcReply
	if err := json.Unmarshal(line, &reply); err != nil {
		return nil, fmt.Errorf("%s: the reply was not JSON-RPC (%w): %s", method, err, firstLine(line))
	}
	if reply.ID != id {
		return nil, fmt.Errorf(
			"%s: the reply carries id %d, not %d — the stream is out of step and no further "+
				"answer on it can be trusted", method, reply.ID, id)
	}
	if reply.Error != nil {
		return nil, fmt.Errorf("%s: %w", method, reply.Error)
	}
	return reply.Result, nil
}

// initializeReply is the part of `initialize`'s result the harness reads.
type initializeReply struct {
	ServerInfo struct {
		Name string `json:"name"`
	} `json:"serverInfo"`
	Meta struct {
		Place  *Place `json:"wakil/place"`
		Screen *Place `json:"wakil/screen"`
		// Conversation is the conversation every call on the socket is made
		// for, and ScreenConversation the one the window shows; either is
		// absent (or null) from a build before conversations, or when the
		// window does not know.
		Conversation       *string `json:"wakil/conversation"`
		ScreenConversation *string `json:"wakil/screenConversation"`
		// HarnessFailure is why the e2e fixture's operator socket beside this one would not
		// start (`harnessSocketFailure` in HarnessChannel.swift); absent from every other build
		// and whenever it started.
		HarnessFailure string `json:"wakil/harnessFailure"`
	} `json:"_meta"`
}

func (m *MCP) initialize() (initializeReply, error) {
	var payload initializeReply
	result, err := m.Do("initialize", map[string]interface{}{
		"protocolVersion": "2024-11-05",
		"capabilities":    map[string]interface{}{},
		"clientInfo":      map[string]interface{}{"name": "wakil-e2e", "version": "1"},
	})
	if err != nil {
		return payload, err
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		return payload, fmt.Errorf("initialize: %w", err)
	}
	if payload.ServerInfo.Name == "" {
		return payload, fmt.Errorf("initialize: the server named itself nothing, so this is not Wakil's socket")
	}
	return payload, nil
}

// Initialize performs the MCP handshake and returns the server's own name.
func (m *MCP) Initialize() (string, error) {
	payload, err := m.initialize()
	return payload.ServerInfo.Name, err
}

// HarnessFailure is why the operator socket beside this one would not start, or "" when the
// socket says nothing: it started, or this build opens none.
func (m *MCP) HarnessFailure() (string, error) {
	payload, err := m.initialize()
	return payload.Meta.HarnessFailure, err
}

// Probe asks the socket, through its own `initialize`, which place and
// conversation every call on it is made for and which the window shows as it
// answers (`initializeMeta` in MCPServer.swift). Screen is nil when the window
// did not say, Conversation empty and ScreenConversation nil likewise. Path is
// left for the caller. The server keeps no handshake state, so this can be
// asked again on a connection already in use.
func (m *MCP) Probe() (SocketPlace, error) {
	payload, err := m.initialize()
	if err != nil {
		return SocketPlace{}, err
	}
	if payload.Meta.Place == nil {
		return SocketPlace{}, ErrNoPlaceMeta
	}
	probe := SocketPlace{
		Place:              *payload.Meta.Place,
		Screen:             payload.Meta.Screen,
		ScreenConversation: payload.Meta.ScreenConversation,
	}
	if payload.Meta.Conversation != nil {
		probe.Conversation = *payload.Meta.Conversation
	}
	return probe, nil
}

// ErrNoPlaceMeta is what Places answers for a socket whose `initialize`
// carries no `_meta["wakil/place"]`: a Wakil built before the shown-place
// sockets, whose one window-wide socket followed the screen.
var ErrNoPlaceMeta = fmt.Errorf(
	"initialize: no _meta[\"wakil/place\"], so this socket cannot say whose calls it " +
		"makes — a Wakil built before the shown-place sockets")

// Tool is one entry of the action denominator: what the window can be asked
// to do, and whether doing it changes anything.
type Tool struct {
	Name string `json:"name"`
	// ReadOnly is the action's `ActionKind`, as far as anything outside the
	// process can see it: true for `.read`, false for `.control` and
	// `.mutate`. It is what the coverage gate's parity rule is stated in —
	// every action that writes owes a check that drives it down both channels
	// — and `MCPServer.toolListEntry` projects it as `annotations.readOnlyHint`
	// precisely so that question does not have to be answered by reading Swift
	// source across six registrars.
	ReadOnly bool `json:"readOnly"`
}

// Tools lists the actions the live window exposes, with their kinds.
//
// **This is the action denominator** (design §2): `ActionRegistry` is the only
// way to enumerate registered actions from outside the process, and `MCPServer`
// projects every one onto a tool. A count read from source would be a second
// answer to a question the running app already answers.
func (m *MCP) Tools() ([]Tool, error) {
	result, err := m.Do("tools/list", map[string]interface{}{})
	if err != nil {
		return nil, err
	}
	var payload struct {
		Tools []struct {
			Name        string `json:"name"`
			Annotations *struct {
				ReadOnlyHint *bool `json:"readOnlyHint"`
			} `json:"annotations"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		return nil, fmt.Errorf("tools/list: %w", err)
	}
	if len(payload.Tools) == 0 {
		return nil, fmt.Errorf(
			"tools/list returned nothing, so the action denominator is zero and every " +
				"coverage claim measured against it would be vacuous")
	}
	tools := make([]Tool, 0, len(payload.Tools))
	for _, tool := range payload.Tools {
		// **An absent hint is refused rather than assumed.** Go would read a
		// missing `readOnlyHint` as false and make every unannotated action
		// owe a parity check; reading it as true would excuse every write from
		// one. Both are a policy nobody chose, applied silently, to a gate
		// whose whole job is to notice what nobody chose. A window that does
		// not carry the hint is an old build, and saying so sends the reader
		// to the bundle rather than to the check files.
		if tool.Annotations == nil || tool.Annotations.ReadOnlyHint == nil {
			return nil, fmt.Errorf(
				"tools/list: %q carries no annotations.readOnlyHint, so this window cannot "+
					"say which of its actions write, and the parity rule cannot be applied "+
					"to any of them", tool.Name)
		}
		tools = append(tools, Tool{Name: tool.Name, ReadOnly: *tool.Annotations.ReadOnlyHint})
	}
	return tools, nil
}

// ToolResult is one `tools/call` reply.
type ToolResult struct {
	// Text is the concatenated text content blocks — what an agent reads.
	Text string
	// Structured is `structuredContent`, which `read_pane` fills with the
	// pane snapshot. It postdates protocol 2024-11-05, which is why the text
	// block carries the answer too.
	Structured json.RawMessage
}

// Call dispatches one action over the socket, exactly as the agent would.
//
// **This is the second drive channel, and it is what makes parity possible.**
// Invariant 2 forbids two code paths to the same state; a parity check performs
// an action once by clicking and once through here and asserts the state landed
// identically. Nothing a fake-injecting unit test does can see that.
func (m *MCP) Call(action string, arguments map[string]interface{}) (ToolResult, error) {
	if arguments == nil {
		arguments = map[string]interface{}{}
	}
	result, err := m.Do("tools/call", map[string]interface{}{
		"name": action, "arguments": arguments,
	})
	if err != nil {
		return ToolResult{}, err
	}
	return ParseToolResult(result)
}

// ReadPane asks the window what a pane contains.
func (m *MCP) ReadPane(paneID string) (ToolResult, error) {
	return m.Call("read_pane", map[string]interface{}{"paneId": paneID})
}

// ReadLayout asks the window what panes it holds.
func (m *MCP) ReadLayout() (ToolResult, error) {
	return m.Call("read_layout", nil)
}

// ParseToolResult decodes a `tools/call` result.
//
// **An `isError` result is an error here**, not a value a check can assert
// against by accident. The MCP convention returns a refusal as a successful
// JSON-RPC reply carrying `isError: true`, and a client that handed that back
// as ordinary content would let a check "read" a pane that refused to be read.
func ParseToolResult(result json.RawMessage) (ToolResult, error) {
	var payload struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		StructuredContent json.RawMessage `json:"structuredContent"`
		IsError           bool            `json:"isError"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		return ToolResult{}, fmt.Errorf("the tool result was not readable: %w", err)
	}
	var text strings.Builder
	for _, block := range payload.Content {
		if block.Type == "text" {
			text.WriteString(block.Text)
		}
	}
	if payload.IsError {
		return ToolResult{}, fmt.Errorf("the action was refused: %s", text.String())
	}
	if len(payload.Content) == 0 && payload.StructuredContent == nil {
		return ToolResult{}, fmt.Errorf("the tool returned neither content nor structuredContent")
	}
	return ToolResult{Text: text.String(), Structured: payload.StructuredContent}, nil
}
