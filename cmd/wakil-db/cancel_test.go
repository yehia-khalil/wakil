package main

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// resultWriter signals when the server writes a tool result — the handler returning.
type resultWriter struct{ ch chan time.Time }

func (w *resultWriter) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte(`"isError"`)) || bytes.Contains(p, []byte(`"structuredContent"`)) {
		select {
		case w.ch <- time.Now():
		default:
		}
	}
	return len(p), nil
}

// The window cancels a read by cancelling the call: the go-sdk client sends
// notifications/cancelled, the server cancels the handler's ctx, and the
// driver's QueryContext ends. Observable: the handler returns within 2 s.
func TestACancelledQueryEndsTheHandler(t *testing.T) {
	setupSQLiteEventsProject(t)

	rw := &resultWriter{ch: make(chan time.Time, 1)}
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(context.Background(),
		&mcp.LoggingTransport{Transport: serverTransport, Writer: rw}, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "wakil-db-cancel-test", Version: "0.0.0"}, nil).
		Connect(context.Background(), clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = cs.CallTool(ctx, &mcp.CallToolParams{Name: "query", Arguments: map[string]any{
			"query": "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 2000000000) SELECT max(x) AS n FROM c",
		}})
	}()
	time.Sleep(300 * time.Millisecond)
	cancelledAt := time.Now()
	cancel()

	select {
	case at := <-rw.ch:
		if waited := at.Sub(cancelledAt); waited > 2*time.Second {
			t.Fatalf("the handler returned %s after the cancel — that is the query finishing, not a cancel", waited)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the handler was still running 10 s after the cancel")
	}
	<-done
}
