// Package driver is the e2e harness's library half: the parts that can be
// tested without a GUI session. Everything here is ordinary Go and runs in
// `make test`; the half that needs a real window is the program at
// e2e/cmd/wakil-e2e, which `make e2e` invokes and nothing else runs.
//
// The split is deliberate, and so is the absence of a build tag. The design
// (docs/superpowers/specs/2026-09-23-agent-e2e-design.md §3) put the whole of
// e2e/ behind `//go:build e2e` to keep a GUI out of `make test`. The goal was
// right and the mechanism was wrong: a tag over e2e/ would have excluded these
// tests too, and they are precisely the guards that stop a check silently
// asserting nothing. A program needs no tag — it compiles under
// `go build ./...` and runs only when something runs it.
package driver

import (
	"fmt"
	"io/fs"
	"os"
	"strings"
)

// OrcaCandidates is where the Orca CLI is looked for, in order.
//
// **Bare `orca` on PATH is deliberately absent and must stay absent.**
// /usr/local/bin/orca is a root-owned symlink with mode lrwx------, so the
// CLI cannot read its own link target through it and every invocation —
// including `--version` and `skills get` — dies with "Unable to determine
// Orca.app path from symlink". Escalated permissions do not help; the mode is
// on the link. Measured 2026-09-23, docs/wakil/agent-e2e-probe.md §6.
//
// A PATH fallback would therefore convert a loud, nameable failure into a
// confusing one, and — worse — could silently target a different Orca build
// than the one the checks were written against.
var OrcaCandidates = []string{
	"/Applications/Orca.app/Contents/Resources/bin/orca",
}

// ResolveOrca returns the Orca CLI to drive this run with.
//
// override, when non-empty, is used or the call fails: a caller that named a
// specific build must never be handed a different one instead.
func ResolveOrca(override string) (string, error) {
	if override != "" {
		if err := executable(override); err != nil {
			return "", fmt.Errorf("orca override %q is unusable: %w", override, err)
		}
		return override, nil
	}
	for _, candidate := range OrcaCandidates {
		if executable(candidate) == nil {
			return candidate, nil
		}
	}
	return "", fmt.Errorf(
		"no usable Orca CLI found in %s — install Orca, or pass one explicitly; "+
			"note that bare `orca` on PATH is not a fallback, because /usr/local/bin/orca "+
			"is a symlink the CLI cannot read its own target through",
		strings.Join(OrcaCandidates, ", "))
}

// executable reports whether path is a regular file with an execute bit.
func executable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("is a directory")
	}
	if info.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("is not executable (mode %s)", fs.FileMode(info.Mode().Perm()))
	}
	return nil
}

// AXResolveBinary is where `make axresolve` puts the resolver.
//
// **Under e2e/bin, not bin/.** `bin/` holds the five Go binaries
// `make app-bundle` copies into `Wakil.app/Contents/Resources`, and a test
// helper does not belong in a shipped bundle even by accident.
const AXResolveBinary = "e2e/bin/axresolve"

// ResolveAXResolve returns the resolver to read this run's trees with.
//
// override, when non-empty, is used or the call fails — the same rule
// ResolveOrca holds: a caller that named a specific build must never be handed
// a different one instead.
func ResolveAXResolve(override string) (string, error) {
	if override != "" {
		if err := executable(override); err != nil {
			return "", fmt.Errorf("axresolve override %q is unusable: %w", override, err)
		}
		return override, nil
	}
	if err := executable(AXResolveBinary); err != nil {
		return "", fmt.Errorf(
			"no resolver at %s (%w) — run `make axresolve`. Without it no identifier can "+
				"be resolved at all, because `orca computer get-app-state` does not emit "+
				"identifiers (docs/wakil/agent-e2e-probe.md §4b)",
			AXResolveBinary, err)
	}
	return AXResolveBinary, nil
}
