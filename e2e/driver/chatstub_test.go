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

// TestChatStubDraftsACommitMessage — 3a-ii-b: a commit-draft request (its
// instructions ask for a git commit message) gets CommitDraftReply, whatever
// the diff in its input says.
func TestChatStubDraftsACommitMessage(t *testing.T) {
	origin, stop, err := StartChatStub()
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	body := `{"messages":[{"role":"system","content":"Write a git commit message for the change below."},{"role":"user","content":"Files:\nREADME.md +1 −1"}]}`
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
		t.Fatalf("decoding: %v %#v", err, out)
	}
	if got := out.Choices[0].Message.Content; got != CommitDraftReply {
		t.Errorf("a commit draft answered %s", got)
	}
}

// TestChatStubNamesATabGroup — 3d-i: a request to name a browser tab group (its
// instructions open with BrowserGroupNames' phrase) gets GroupNameReply, whatever
// the titles in its input say.
func TestChatStubNamesATabGroup(t *testing.T) {
	origin, stop, err := StartChatStub()
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	body := `{"messages":[{"role":"system","content":"Name this group of browser tabs from their titles. Answer with at most three words and no punctuation, as JSON: {\"name\": \"...\"}."},{"role":"user","content":"Page A\nPage B"}]}`
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
		t.Fatalf("decoding: %v %#v", err, out)
	}
	if got := out.Choices[0].Message.Content; got != GroupNameReply {
		t.Errorf("a group name answered %s", got)
	}
}
