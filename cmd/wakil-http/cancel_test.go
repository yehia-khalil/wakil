package main

import (
	"bytes"
	"context"
	"net"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// stallListener accepts TCP connections and never answers. A TLS client's
// handshake waits on it until the client gives up, so a request to it is on
// the wire and going nowhere — the shape of a slow server, with no
// certificate to trust. closed receives the moment the CLIENT closes a
// connection. It is kept only so the request has somewhere to stall.
func stallListener(t *testing.T) (addr string, closed <-chan time.Time) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	ch := make(chan time.Time, 4)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				for {
					if _, err := c.Read(buf); err != nil {
						ch <- time.Now()
						return
					}
				}
			}(conn)
		}
	}()
	return ln.Addr().String(), ch
}

// resultWriter signals when the server writes a tool result (an "isError" or
// "structuredContent" message), which is the handler returning.
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

// W14: a call the window stops waiting for must stop the HTTP request too.
// The go-sdk client sends notifications/cancelled when CallTool's context is
// cancelled; the server's canceller cancels the handler's ctx; DoRequest and
// DoSend build the request with that ctx. The observable is the handler
// RETURNING (the server writes its tool result) within 2 s of the cancel.
// Socket close is not the observable: Go's transport deliberately lets an
// abandoned dial finish in the background for pool reuse, so the stalled
// socket outlives the abort until the 10 s TLS handshake timeout. Without the
// ctx threading the handler is stuck in that handshake and writes nothing
// until then.
func TestACancelledCallAbortsTheHTTPRequest(t *testing.T) {
	for _, tc := range []struct {
		tool string
		args map[string]any
	}{
		{"request", map[string]any{"method": "GET", "path": "/stall"}},
		{"send", map[string]any{"method": "POST", "path": "/stall", "body": "{}"}},
	} {
		t.Run(tc.tool, func(t *testing.T) {
			addr, _ := stallListener(t)
			setupProject(t,
				`"staging":{"databases":[],"api":[{"name":"slow","baseUrl":"https://`+addr+`"}]}`,
				"staging")
			t.Setenv(wakilcore.WindowMarkerEnv, "1")

			rw := &resultWriter{ch: make(chan time.Time, 1)}
			serverTransport, clientTransport := mcp.NewInMemoryTransports()
			ss, err := newServer().Connect(context.Background(), &mcp.LoggingTransport{Transport: serverTransport, Writer: rw}, nil)
			if err != nil {
				t.Fatalf("server Connect: %v", err)
			}
			t.Cleanup(func() { ss.Close() })
			cs, err := mcp.NewClient(&mcp.Implementation{Name: "wakil-http-cancel-test", Version: "0.0.0"}, nil).Connect(context.Background(), clientTransport, nil)
			if err != nil {
				t.Fatalf("client Connect: %v", err)
			}
			t.Cleanup(func() { cs.Close() })

			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() {
				defer close(done)
				_, _ = cs.CallTool(ctx, &mcp.CallToolParams{Name: tc.tool, Arguments: tc.args})
			}()
			// Long enough to dial and send the ClientHello: the request is on the wire.
			time.Sleep(300 * time.Millisecond)
			cancelledAt := time.Now()
			cancel()

			select {
			case at := <-rw.ch:
				if waited := at.Sub(cancelledAt); waited > 2*time.Second {
					t.Fatalf("the handler returned %s after the cancel — that is a timeout, not an abort", waited)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("the handler was still running 5 s after the cancel: wakil-http did not abort the request")
			}
			<-done
		})
	}
}
