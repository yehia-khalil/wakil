package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The bare `orca` on PATH is not a candidate and must never become one:
// /usr/local/bin/orca is a root-owned symlink the CLI cannot read its own
// target through, so every invocation dies with "Unable to determine
// Orca.app path from symlink" — including --version. A fallback to it would
// turn a loud failure into a confusing one. See docs/wakil/agent-e2e-probe.md §6.
func TestResolveOrcaNeverFallsBackToBarePATH(t *testing.T) {
	withCandidates(t, nil)
	if got, err := ResolveOrca(""); err == nil {
		t.Fatalf("want an error when no candidate exists, got %q", got)
	}
}

func TestResolveOrcaUsesFirstExistingCandidate(t *testing.T) {
	dir := t.TempDir()
	second := touchExecutable(t, dir, "second")
	withCandidates(t, []string{filepath.Join(dir, "missing"), second})

	got, err := ResolveOrca("")
	if err != nil {
		t.Fatalf("ResolveOrca: %v", err)
	}
	if got != second {
		t.Fatalf("got %q, want %q", got, second)
	}
}

func TestResolveOrcaOverrideWins(t *testing.T) {
	dir := t.TempDir()
	candidate := touchExecutable(t, dir, "candidate")
	override := touchExecutable(t, dir, "override")
	withCandidates(t, []string{candidate})

	got, err := ResolveOrca(override)
	if err != nil {
		t.Fatalf("ResolveOrca: %v", err)
	}
	if got != override {
		t.Fatalf("got %q, want the override %q", got, override)
	}
}

// An override that does not exist is an error, never a silent fall-through
// to a candidate: the caller named a specific build and must not be given a
// different one.
func TestResolveOrcaMissingOverrideDoesNotFallThrough(t *testing.T) {
	dir := t.TempDir()
	withCandidates(t, []string{touchExecutable(t, dir, "candidate")})

	_, err := ResolveOrca(filepath.Join(dir, "absent"))
	if err == nil {
		t.Fatal("want an error for a missing override, got nil")
	}
	if !strings.Contains(err.Error(), "absent") {
		t.Fatalf("error must name the path it could not use, got %q", err)
	}
}

func TestResolveOrcaRejectsNonExecutableCandidate(t *testing.T) {
	dir := t.TempDir()
	plain := filepath.Join(dir, "plain")
	if err := os.WriteFile(plain, []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withCandidates(t, []string{plain})

	if _, err := ResolveOrca(""); err == nil {
		t.Fatal("want an error for a non-executable candidate, got nil")
	}
}

func withCandidates(t *testing.T, candidates []string) {
	t.Helper()
	previous := OrcaCandidates
	OrcaCandidates = candidates
	t.Cleanup(func() { OrcaCandidates = previous })
}

func touchExecutable(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}
