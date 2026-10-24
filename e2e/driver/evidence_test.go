package driver

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Orca writes the capture to a temporary file with a TTL and hands back its
// path, so evidence must COPY it. A path recorded instead would be dangling
// by the time anyone read it.
func TestEvidenceCopiesTheScreenshotRatherThanReferencingIt(t *testing.T) {
	shot := filepath.Join(t.TempDir(), "capture.png")
	if err := os.WriteFile(shot, []byte("\x89PNG\r\n\x1a\nfake"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := `{"ok":true,"result":{"screenshotStatus":{"state":"captured"},` +
		`"screenshot":{"path":"` + shot + `"},` +
		`"snapshot":{"elementCount":9,"treeText":"0 standard window Wakil\n"}}}`
	exe, _ := fakeOrca(t, body, 0)
	dir := t.TempDir()
	evidence := &Evidence{Dir: dir}

	evidence.Capture(Orca{Exe: exe}, 44187, nil, "landing")
	if err := evidence.Record("landing", []string{"the tree did not contain X"}); err != nil {
		t.Fatalf("Record: %v", err)
	}

	copied, err := os.ReadFile(filepath.Join(dir, "landing", "screenshot.png"))
	if err != nil {
		t.Fatalf("the screenshot was not copied: %v", err)
	}
	if !strings.HasPrefix(string(copied), "\x89PNG") {
		t.Fatalf("the copy is not the capture: %q", string(copied))
	}
	// The original may be reaped at any time; the copy must survive it.
	if err := os.Remove(shot); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "landing", "screenshot.png")); err != nil {
		t.Fatalf("the copy did not survive the original: %v", err)
	}
}

// **A failure to gather evidence must never mask the failure it was gathering
// evidence about.** A harness that dropped the original failure when its
// screenshot failed would be worse than one that took no screenshots.
func TestEvidenceStillRecordsTheFailureWhenTheCaptureFails(t *testing.T) {
	exe, _ := fakeOrca(t, `{"ok":false,"error":{"code":"permission_denied","message":"AX reads stayed blocked"}}`, 1)
	dir := t.TempDir()
	evidence := &Evidence{Dir: dir}

	evidence.Capture(Orca{Exe: exe}, 44187, nil, "landing")
	if err := evidence.Record("landing", []string{"the tree did not contain X"}); err != nil {
		t.Fatalf("Record: %v", err)
	}

	recorded, err := os.ReadFile(filepath.Join(dir, "landing", "failure.txt"))
	if err != nil {
		t.Fatalf("the failure itself was not recorded: %v", err)
	}
	if !strings.Contains(string(recorded), "did not contain X") {
		t.Fatalf("failure.txt = %q", string(recorded))
	}
	gaps, err := os.ReadFile(filepath.Join(dir, "landing", "evidence-gaps.txt"))
	if err != nil {
		t.Fatalf("what could not be gathered must be written down: %v", err)
	}
	if !strings.Contains(string(gaps), "permission_denied") {
		t.Fatalf("the gap must name why, got %q", string(gaps))
	}
}

// The layout says which panes exist; what a pane CONTAINS is `read_pane`'s
// question, and #251 asks for that snapshot by name.
func TestEvidenceSnapshotsEveryPaneNotJustTheLayout(t *testing.T) {
	exe, _ := fakeOrca(t, stateJSON, 0)
	dir := t.TempDir()
	channel := &fakeChannel{results: map[string]string{
		"read_layout": `{"focusedId":"db-1","panes":[{"id":"db-1"},{"id":"terminal-1"}]}`,
		"read_pane":   `{"id":"db-1","kind":"db"}`,
	}}
	evidence := &Evidence{Dir: dir}

	evidence.Capture(Orca{Exe: exe}, 44187, channel, "landing")

	body, err := os.ReadFile(filepath.Join(dir, "landing", "panes.json"))
	if err != nil {
		t.Fatalf("no pane snapshot: %v", err)
	}
	var snapshot struct {
		Panes map[string]json.RawMessage `json:"panes"`
	}
	if err := json.Unmarshal(body, &snapshot); err != nil {
		t.Fatalf("panes.json is not readable: %v\n%s", err, body)
	}
	for _, id := range []string{"db-1", "terminal-1"} {
		if _, carried := snapshot.Panes[id]; !carried {
			t.Fatalf("pane %q was not snapshotted, got %s", id, body)
		}
	}
	var called int
	for _, call := range channel.calls {
		if strings.HasPrefix(call, "read_pane ") {
			called++
		}
	}
	if called != 2 {
		t.Fatalf("read_pane was called %d time(s), want one per pane", called)
	}
}

// **A turn that never started is the finding, not a missing artefact. #284.**
//
// The commonest way an agent check fails is that the window never launched the
// agent at all: no `started:` line, no `prompt:`, no log file. Recording that
// as "the agent's log could not be copied: no such file" files the evidence
// under a gap, where it reads as the harness having broken rather than as the
// one fact that explains the red.
func TestEvidenceSaysSoWhenTheAgentWasNeverRun(t *testing.T) {
	dir := t.TempDir()
	never := filepath.Join(t.TempDir(), "claude-e2e-provider", "e2e-agent-log.txt")
	evidence := &Evidence{Dir: dir, AgentLog: never}

	if err := evidence.Record("both-surfaces", []string{"the tree does not contain the reply"}); err != nil {
		t.Fatalf("Record: %v", err)
	}

	recorded, err := os.ReadFile(filepath.Join(dir, "both-surfaces", "agent-log.txt"))
	if err != nil {
		t.Fatalf("the agent's log must be written even when there was none: %v", err)
	}
	if !strings.Contains(string(recorded), "the agent was never run") {
		t.Fatalf("agent-log.txt must say what happened, got %q", string(recorded))
	}
	if !strings.Contains(string(recorded), never) {
		t.Fatalf("it must name the path it looked at, got %q", string(recorded))
	}
	// Not a gap: a gap says an artefact is missing, and this artefact is here.
	if _, err := os.Stat(filepath.Join(dir, "both-surfaces", "evidence-gaps.txt")); err == nil {
		gaps, _ := os.ReadFile(filepath.Join(dir, "both-surfaces", "evidence-gaps.txt"))
		if strings.Contains(string(gaps), "agent") {
			t.Fatalf("a turn that never started must not be filed as a gap, got %q", string(gaps))
		}
	}
}

// The ordinary case still lands: a log that exists is what the evidence holds.
func TestEvidenceCarriesTheAgentLogWhenThereIsOne(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(t.TempDir(), "e2e-agent-log.txt")
	if err := os.WriteFile(logPath, []byte("started: 2 rule(s)\nprompt: \"what did it print?\"\nanswered\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	evidence := &Evidence{Dir: dir, AgentLog: logPath}

	if err := evidence.Record("both-surfaces", []string{"something else failed"}); err != nil {
		t.Fatalf("Record: %v", err)
	}

	recorded, err := os.ReadFile(filepath.Join(dir, "both-surfaces", "agent-log.txt"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"started:", "prompt:", "answered"} {
		if !strings.Contains(string(recorded), want) {
			t.Fatalf("agent-log.txt lost %q: %q", want, string(recorded))
		}
	}
}

// #15: a fixture that went away mid-check is written down as gone, with what macOS said about
// it — not left as an app_not_found that reads like the harness losing the pid.
func TestEvidenceSaysWhenTheFixtureIsGone(t *testing.T) {
	exe, _ := fakeOrca(t, `{"ok":false,"error":{"code":"app_not_found","message":"app 'pid:1' not found"}}`, 1)
	gone := exec.Command("/usr/bin/true")
	if err := gone.Run(); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	evidence := &Evidence{Dir: dir, GoneFixture: func(pid int) string { return "the log for it" }}

	evidence.Capture(Orca{Exe: exe}, gone.Process.Pid, nil, "landing")

	body, err := os.ReadFile(filepath.Join(dir, "landing", "fixture-gone.txt"))
	if err != nil {
		t.Fatalf("fixture-gone.txt was not written: %v", err)
	}
	if !strings.Contains(string(body), "is no longer running") || !strings.Contains(string(body), "the log for it") {
		t.Fatalf("fixture-gone.txt = %q", string(body))
	}

	// A running fixture writes none.
	alive := &Evidence{Dir: t.TempDir(), GoneFixture: func(int) string { return "" }}
	alive.Capture(Orca{Exe: exe}, os.Getpid(), nil, "landing")
	if _, err := os.Stat(filepath.Join(alive.Dir, "landing", "fixture-gone.txt")); err == nil {
		t.Fatal("fixture-gone.txt was written for a running process")
	}
}
