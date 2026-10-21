package driver

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

func askStub(t *testing.T, origin, line string) string {
	t.Helper()
	body := `{"messages":[{"role":"system","content":"x"},{"role":"user","content":"SCOPE: {}\nLINE: ` + line + `"}]}`
	resp, err := http.Post(origin+"/v1/chat/completions", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Choices []struct {
			Message struct{ Content string } `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Choices) != 1 {
		t.Fatalf("decoding the stub's answer: %v %#v", err, out)
	}
	return out.Choices[0].Message.Content
}

// TestChatStubAnswersTheTableAndAgentOtherwise — a known line gets its
// scripted action, anything else the model's "agent".
func TestChatStubAnswersTheTableAndAgentOtherwise(t *testing.T) {
	origin, stop, err := StartChatStub()
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if got := askStub(t, origin, "Go to QA"); got != FastPathReplies["go to qa"] {
		t.Errorf("go to qa answered %s", got)
	}
	if got := askStub(t, origin, "how does refund work?"); got != `{"action":"agent","params":{}}` {
		t.Errorf("a question answered %s", got)
	}
}

// TestChatStubAnswersASlowLineLate — the deadline check needs an answer that
// arrives, and arrives after 400 ms.
func TestChatStubAnswersASlowLineLate(t *testing.T) {
	origin, stop, err := StartChatStub()
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	start := time.Now()
	if got := askStub(t, origin, "slow go to qa"); got != FastPathReplies["go to qa"] {
		t.Errorf("slow go to qa answered %s", got)
	}
	if took := time.Since(start); took < SlowReply {
		t.Errorf("answered in %v, before %v", took, SlowReply)
	}
}
