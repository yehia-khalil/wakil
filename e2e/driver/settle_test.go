package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// **An agent launch waits for a subprocess, not for a redraw.**
//
// `both-surfaces.jsonl` went red once in five on the fix's own build, at the
// one assertion that waits on the agent: the reply was not in the tree three
// seconds after Send, while every step after it passed. The turn spawns a
// child, hands it a generated `--mcp-config`, waits for it to connect back
// over the window's socket and answers a `read_pane` on it — three seconds is
// the "short enough to be cheap is a flake" case DefaultSettle's own comment
// names.
func TestASettleIsChosenForWhatTheLaunchWaitsOn(t *testing.T) {
	for _, tc := range []struct {
		name     string
		explicit time.Duration
		hasAgent bool
		want     time.Duration
	}{
		{"no agent takes the window's settle", 0, false, DefaultSettle},
		{"an agent launch takes the subprocess settle", 0, true, AgentSettle},
		{"an explicit settle wins over both", 250 * time.Millisecond, true, 250 * time.Millisecond},
		// Negative is how a caller asks for no waiting at all, and an agent
		// launch must not quietly reinstate it.
		{"no waiting stays no waiting", -1, true, -1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := settleFor(tc.explicit, tc.hasAgent); got != tc.want {
				t.Fatalf("settleFor(%v, %v) = %v, want %v", tc.explicit, tc.hasAgent, got, tc.want)
			}
		})
	}
	if AgentSettle <= DefaultSettle {
		t.Fatalf("AgentSettle (%v) must exceed DefaultSettle (%v) or it is not doing anything",
			AgentSettle, DefaultSettle)
	}
}

// **A turn that never started must not be waitable-out.** `AgentSettle` is a
// deadline for a turn that is slow; the one thing it must never cover is a
// turn that never happened, which is what `e2e.md`'s "never retry a check into
// green" is actually about. So that case is a FATAL fault of the run — no
// assertion, no deadline, nothing to re-read.
func TestAnAgentLaunchThatNeverRanTheAgentIsFatal(t *testing.T) {
	session := Session{Agent: AgentFixture{Stub: "/nowhere/wakil-e2e-agent", Script: "s.json"}}
	missing := filepath.Join(t.TempDir(), "claude-e2e-provider", AgentStubLogFile)

	faults := session.agentNeverRan(missing)

	if len(faults) != 1 {
		t.Fatalf("want one fault, got %v", faults)
	}
	if !strings.Contains(faults[0], "never launched the scripted agent") {
		t.Fatalf("the fault must say what happened, got %q", faults[0])
	}
	if !strings.Contains(faults[0], missing) {
		t.Fatalf("it must name the path it looked at, got %q", faults[0])
	}
}

// A launch that ran the agent, and one that never seeded an agent at all, are
// both silent here — the second because most checks want no agent, and a fault
// on every one of them would be noise nobody reads.
func TestAgentNeverRanIsSilentWhenThereIsNothingToReport(t *testing.T) {
	present := filepath.Join(t.TempDir(), AgentStubLogFile)
	if err := os.WriteFile(present, []byte("started: 2 rule(s)\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ran := Session{Agent: AgentFixture{Stub: "/somewhere/agent", Script: "s.json"}}
	if faults := ran.agentNeverRan(present); faults != nil {
		t.Fatalf("a launch whose agent ran must report nothing, got %v", faults)
	}
	noAgent := Session{}
	if faults := noAgent.agentNeverRan(""); faults != nil {
		t.Fatalf("a launch with no agent must report nothing, got %v", faults)
	}
}
