package driver

import (
	"strings"
	"testing"
)

// Addressing by bundle id is the failure this guard exists to prevent. With
// two Wakils running, `orca computer list-windows --app dev.wakil.app`
// returned only the operator's — no error, no indication a second existed
// (docs/wakil/agent-e2e-probe.md §1). So the runner must establish exactly
// one new pid and address it by `pid:<n>`, or refuse to run at all.
func TestNewPIDPicksTheOneThatAppeared(t *testing.T) {
	got, err := NewPID([]int{10429, 42901}, []int{10429, 42901, 44187})
	if err != nil {
		t.Fatalf("NewPID: %v", err)
	}
	if got != 44187 {
		t.Fatalf("got %d, want 44187", got)
	}
}

func TestNewPIDRefusesWhenNothingAppeared(t *testing.T) {
	_, err := NewPID([]int{10429}, []int{10429})
	if err == nil {
		t.Fatal("want an error when the launch produced no new process")
	}
}

// Two new pids means the runner cannot say which instance is its own, and an
// instance it cannot identify is one it must not drive.
func TestNewPIDRefusesWhenSeveralAppeared(t *testing.T) {
	_, err := NewPID([]int{10429}, []int{10429, 44187, 44188})
	if err == nil {
		t.Fatal("want an error when two processes appeared")
	}
	if !strings.Contains(err.Error(), "44187") || !strings.Contains(err.Error(), "44188") {
		t.Fatalf("error must name the candidates so the operator can clean up, got %q", err)
	}
}

// A process that vanished between the two samples must not be mistaken for a
// new one, and must not make an otherwise clean launch fail.
func TestNewPIDIgnoresProcessesThatDisappeared(t *testing.T) {
	got, err := NewPID([]int{10429, 42901}, []int{10429, 44187})
	if err != nil {
		t.Fatalf("NewPID: %v", err)
	}
	if got != 44187 {
		t.Fatalf("got %d, want 44187", got)
	}
}
