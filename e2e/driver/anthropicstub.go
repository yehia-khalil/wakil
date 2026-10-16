package driver

import (
	"io"
	"net"
	"net/http"
)

// DefaultStubCapacityHeaders are what the stub API answers every probe
// with: 12% of the 5-hour window and 59% of the week left, both resetting
// 2099-06-15T12:00:00Z — the figures the capacity checks read.
var DefaultStubCapacityHeaders = map[string]string{
	"anthropic-ratelimit-unified-5h-utilization": "0.88",
	"anthropic-ratelimit-unified-5h-reset":       "4085222400",
	"anthropic-ratelimit-unified-7d-utilization": "0.41",
	"anthropic-ratelimit-unified-7d-reset":       "4085222400",
}

// StartAnthropicStub serves the capacity probe locally, so an e2e run
// never spends a real account's limit or depends on the network.
func StartAnthropicStub(headers map[string]string) (string, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		for k, v := range headers {
			w.Header().Set(k, v)
		}
		w.Header().Set("content-type", "application/json")
		io.WriteString(w, `{"type":"message","content":[]}`)
	})}
	go srv.Serve(ln)
	return "http://" + ln.Addr().String(), func() { srv.Close() }, nil
}
