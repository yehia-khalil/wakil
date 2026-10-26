package driver_test

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func TestMCPInitializeNamesTheServer(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id, `{"protocolVersion":"2024-11-05","serverInfo":{"name":"wakil","version":"2a"}}`)
	})
	name, err := client.Initialize()
	if err != nil {
		t.Fatal(err)
	}
	if name != "wakil" {
		t.Errorf("got %q, want wakil", name)
	}
}

// A server that names itself nothing is not Wakil's socket, and connecting to
// the wrong thing must fail here rather than at the first assertion.
func TestMCPInitializeRefusesAnAnonymousServer(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id, `{"protocolVersion":"2024-11-05","serverInfo":{}}`)
	})
	if _, err := client.Initialize(); err == nil {
		t.Error("a server that named itself nothing was accepted")
	}
}

// **The action denominator must not be zero.** Design §2 measures action
// coverage against this list; an empty one makes every later claim vacuous
// while the call itself looks like a success.
func TestMCPToolsRefusesAnEmptyRegistry(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id, `{"tools":[]}`)
	})
	if _, err := client.Tools(); err == nil {
		t.Error("an empty tools/list was accepted as the action denominator")
	}
}

func TestMCPToolsListsTheActions(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id, `{"tools":[`+
			`{"name":"term_open","annotations":{"readOnlyHint":false}},`+
			`{"name":"read_pane","annotations":{"readOnlyHint":true}}]}`)
	})
	tools, err := client.Tools()
	if err != nil {
		t.Fatal(err)
	}
	if len(tools) != 2 || tools[0].Name != "term_open" {
		t.Errorf("got %v", tools)
	}
	if tools[0].ReadOnly || !tools[1].ReadOnly {
		t.Errorf("the kinds did not survive the wire: %v", tools)
	}
}

// **A tool with no `readOnlyHint` is a fault in the run, not a read.** The
// hint is what says which actions owe a parity check (#256); absent, the
// honest answer is that this window cannot say, and defaulting to Go's false
// would silently demand parity for every read while defaulting to true would
// silently excuse every write. Either way the gate would be measuring
// something nobody chose.
func TestMCPToolsRefusesAToolThatDoesNotSayWhetherItWrites(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id, `{"tools":[{"name":"term_open"}]}`)
	})
	_, err := client.Tools()
	if err == nil {
		t.Fatal("a tool with no readOnlyHint was accepted")
	}
	if !strings.Contains(err.Error(), "term_open") {
		t.Errorf("the refusal does not name the tool: %v", err)
	}
}

func TestReadPaneReturnsBothHalves(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id, `{"content":[{"type":"text","text":"{\"kind\":\"terminal\"}"}],`+
			`"structuredContent":{"kind":"terminal","shell":"zsh"}}`)
	})
	result, err := client.ReadPane("terminal-1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(result.Text, "terminal") {
		t.Errorf("the text block is %q", result.Text)
	}
	var structured struct{ Shell string }
	if err := json.Unmarshal(result.Structured, &structured); err != nil {
		t.Fatal(err)
	}
	if structured.Shell != "zsh" {
		t.Errorf("structuredContent is %s", result.Structured)
	}
}

// **A refusal arrives as a successful JSON-RPC reply carrying isError.** A
// client that handed it back as ordinary content would let a check "read" a
// pane that refused to be read, and then assert against the refusal text.
func TestParseToolResultTreatsIsErrorAsAnError(t *testing.T) {
	_, err := driver.ParseToolResult(json.RawMessage(
		`{"content":[{"type":"text","text":"no such pane \"db-9\""}],"isError":true}`))
	if err == nil {
		t.Fatal("an isError result was returned as content")
	}
	if !strings.Contains(err.Error(), "db-9") {
		t.Errorf("the refusal lost its text: %v", err)
	}
}

func TestParseToolResultRefusesAnEmptyResult(t *testing.T) {
	if _, err := driver.ParseToolResult(json.RawMessage(`{}`)); err == nil {
		t.Error("a result with neither content nor structuredContent was accepted")
	}
}

// The server answers in order on one connection, so a mismatched id means the
// stream is out of step. Hunting for "our" reply would hide that while
// attributing one call's answer to another.
func TestMCPRefusesAReplyForAnotherRequest(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return reply(id+99, `{"tools":[{"name":"term_open"}]}`)
	})
	_, err := client.Tools()
	if err == nil {
		t.Fatal("a reply carrying the wrong id was accepted")
	}
	if !strings.Contains(err.Error(), "out of step") {
		t.Errorf("the refusal does not say what is wrong: %v", err)
	}
}

func TestMCPSurfacesAJSONRPCError(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return `{"jsonrpc":"2.0","id":` + itoa(id) +
			`,"error":{"code":-32602,"message":"Invalid params: \"read_pane\" requires a string \"paneId\""}}`
	})
	_, err := client.ReadPane("")
	if err == nil {
		t.Fatal("a JSON-RPC error was not surfaced")
	}
	if !strings.Contains(err.Error(), "-32602") {
		t.Errorf("the code was lost: %v", err)
	}
}

// What the window said, without the driver's envelope: the scripted agent reports a refusal in
// these words, and a thread row is read only so far, so `tools/call: -32002: ` must not lead it.
func TestRefusalTextIsTheWindowsOwnWords(t *testing.T) {
	client := dialFake(t, func(method string, id int) string {
		return `{"jsonrpc":"2.0","id":` + itoa(id) +
			`,"error":{"code":-32002,"message":"browser_type: the operator did not allow the agent on 127.0.0.1:5"}}`
	})
	_, err := client.Call("browser_type", nil)
	if err == nil {
		t.Fatal("a JSON-RPC error was not surfaced")
	}
	if got := driver.RefusalText(err); got != "browser_type: the operator did not allow the agent on 127.0.0.1:5" {
		t.Errorf("a JSON-RPC refusal reads %q, want the message alone", got)
	}
	_, err = driver.ParseToolResult(json.RawMessage(
		`{"content":[{"type":"text","text":"no such pane \"db-9\""}],"isError":true}`))
	if got := driver.RefusalText(err); got != `no such pane "db-9"` {
		t.Errorf("an isError refusal reads %q, want its text alone", got)
	}
}

// --- a stand-in server speaking the same wire ---------------------------

func reply(id int, result string) string {
	return `{"jsonrpc":"2.0","id":` + itoa(id) + `,"result":` + result + `}`
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// dialFake starts a Unix socket server that answers each newline-delimited
// request with respond(method, id), which is exactly the framing
// `encodeFrame` produces: one JSON object, one "\n".
func dialFake(t *testing.T, respond func(method string, id int) string) *driver.MCP {
	t.Helper()
	// **Not `t.TempDir()`**, which embeds the test's own name: `sun_path` is
	// 104 bytes on Darwin, and TMPDIR plus a name like
	// `TestMCPRefusesAReplyForAnotherRequest` overran it and failed three of
	// these with `bind: invalid argument`. The same limit
	// `makeUnixSocketAddress` rejects a path for, met from the test side.
	dir, err := os.MkdirTemp("", "m")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "s.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listening on %s: %v", path, err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer conn.Close()
		reader := bufio.NewReader(conn)
		for {
			line, readErr := reader.ReadBytes('\n')
			if readErr != nil {
				return
			}
			var request struct {
				ID     int    `json:"id"`
				Method string `json:"method"`
			}
			if json.Unmarshal(line, &request) != nil {
				return
			}
			if _, writeErr := conn.Write([]byte(respond(request.Method, request.ID) + "\n")); writeErr != nil {
				return
			}
		}
	}()

	client, err := driver.DialMCPPath(path, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}
