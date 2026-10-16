package mcpx_test

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// #242: an integer above 2^53 is exact in JSON and exact in int64, but not
// in float64. The SDK's applySchema round-tripped every tool result through
// `any` with a decoder that had no UseNumber(), so the value was re-marshalled
// from a float64 and left the process wrong by one, silently.
//
// WHAT IS MEASURED HERE IS THE BYTES ON THE WIRE, and that is deliberate.
// Wakil's consumer is Swift reading a stdio pipe, so the bytes the server
// writes are the whole contract. Asserting through the SDK's own Go client
// would measure a different thing: CallToolResult.StructuredContent is
// typed `any`, so a Go client decodes the number into a float64 on the way
// IN, which is a second, separate loss that Wakil never encounters.
//
// The fix lives in a fork pinned by the replace directive in go.mod. See
// docs/wakil/decisions.md.
type bigOut struct {
	ID   int64   `json:"id"`
	Rows [][]any `json:"rows"`
}

const bigID int64 = 9007199254740993 // 2^53 + 1

func TestIntegerAbove2Pow53SurvivesOnTheWire(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s := mcp.NewServer(&mcp.Implementation{Name: "repro", Version: "0.0.0"}, nil)
	mcp.AddTool(s, &mcp.Tool{Name: "big", Description: "returns 2^53+1"},
		func(ctx context.Context, req *mcp.CallToolRequest, in struct{}) (*mcp.CallToolResult, bigOut, error) {
			return nil, bigOut{
				ID:   bigID,
				Rows: [][]any{{bigID, "text", 1.5}},
			}, nil
		})

	// A real stdio transport over pipes, so what the test reads is exactly
	// what a capability process writes to its stdout.
	clientReader, serverWriter := io.Pipe()
	serverReader, clientWriter := io.Pipe()

	go func() {
		ss, err := s.Connect(ctx, &mcp.IOTransport{Reader: serverReader, Writer: serverWriter}, nil)
		if err != nil {
			return
		}
		<-ctx.Done()
		ss.Close()
	}()

	send := func(v any) {
		t.Helper()
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal request: %v", err)
		}
		if _, err := clientWriter.Write(append(raw, '\n')); err != nil {
			t.Fatalf("write request: %v", err)
		}
	}

	lines := bufio.NewScanner(clientReader)
	lines.Buffer(make([]byte, 0, 1<<20), 1<<20)
	readLine := func() string {
		t.Helper()
		if !lines.Scan() {
			t.Fatalf("no response line: %v", lines.Err())
		}
		return lines.Text()
	}

	send(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize",
		"params": map[string]any{
			"protocolVersion": "2025-06-18",
			"capabilities":    map[string]any{},
			"clientInfo":      map[string]any{"name": "repro-client", "version": "0.0.0"},
		},
	})
	readLine() // initialize result
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	send(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": map[string]any{"name": "big", "arguments": map[string]any{}},
	})

	var line string
	for {
		line = readLine()
		if strings.Contains(line, `"id":2`) {
			break
		}
	}
	t.Logf("bytes off the pipe: %s", line)

	// Assert on the TEXT, not on a decoded value: decoding into `any` here
	// would reintroduce the very float64 this test exists to rule out.
	for _, want := range []string{
		`"id":9007199254740993`,
		`9007199254740993`,
	} {
		if !strings.Contains(line, want) {
			t.Errorf("response does not contain %s — the integer was lost in transit\n%s", want, line)
		}
	}
	if strings.Contains(line, "9007199254740992") {
		t.Errorf("response contains 9007199254740992: the integer was round-tripped through float64\n%s", line)
	}
}
