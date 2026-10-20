package driver

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// FastPathReplies is what the chat stub answers a fast-path line with: the
// line an operator typed, mapped to the reply a local model would give. Any
// other line answers "agent", as a model does for a question.
//
// **The stub stands in for the model, and only for the model.** It never
// decides whether an answer is allowed: Wakil's own checks still read every
// reply, which is why the table holds answers Wakil must refuse, such as
// `open nowhere.go`, a path no scope carries.
var FastPathReplies = map[string]string{
	"go to qa":        `{"action":"ctx_set_environment","params":{"name":"qa"}}`,
	"go to staging":   `{"action":"ctx_set_environment","params":{"name":"staging"}}`,
	"open a terminal": `{"action":"term_open","params":{}}`,
	"line 40":         `{"action":"editor_goto","params":{"line":40}}`,
	"open nowhere.go": `{"action":"editor_open","params":{"path":"nowhere.go"}}`,
	// A name relative to the project root, as Wakil now shows a model its files.
	"open fastpath-target.txt": `{"action":"editor_open","params":{"path":"fastpath-target.txt"}}`,
}

// SlowPrefix makes the stub answer late: "slow go to qa" answers as "go to
// qa" does, after SlowReply — past the fast path's 300 ms local deadline.
const SlowPrefix = "slow "

// SlowReply is how long a slow line waits before its answer.
const SlowReply = 1500 * time.Millisecond

// StartChatStub serves `/v1/chat/completions` on loopback, so a fast-path
// check has a local model to point at that answers the same way every run
// and never needs a real one. Infill (`/v1/completions`) answers an empty
// completion, so ghost-text stays quiet.
func StartChatStub() (string, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		line := ""
		if n := len(body.Messages); n > 0 {
			line = FastPathLine(body.Messages[n-1].Content)
		}
		if rest, ok := strings.CutPrefix(line, SlowPrefix); ok {
			line = rest
			select {
			case <-time.After(SlowReply):
			case <-r.Context().Done():
				return
			}
		}
		reply, ok := FastPathReplies[line]
		if !ok {
			reply = `{"action":"agent","params":{}}`
		}
		w.Header().Set("content-type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"choices": []interface{}{map[string]interface{}{
				"message": map[string]interface{}{"role": "assistant", "content": reply},
			}},
		})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		w.Header().Set("content-type", "application/json")
		io.WriteString(w, `{"content":""}`)
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	return "http://" + ln.Addr().String(), func() { srv.Close() }, nil
}

// FastPathLine is the operator's line in a fast-path input: what follows its
// last "LINE: " (FastPath.input in WakilKit), trimmed and lower-cased.
func FastPathLine(input string) string {
	if i := strings.LastIndex(input, "LINE: "); i >= 0 {
		input = input[i+len("LINE: "):]
	}
	return strings.ToLower(strings.TrimSpace(input))
}
