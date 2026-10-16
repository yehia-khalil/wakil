package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestSetupTokenSpeaksOnlyToATerminal is the live instrument for the one
// fact the 2e design got wrong (#240).
//
// **It is skipped unless `WAKIL_CLAUDE_BINARY` names a real `claude`**,
// because it starts a genuine OAuth flow: the CLI opens a browser by
// itself. It stops well before anything is approved, so it creates no
// credential and owes no revocation — it is only asking whether the tool
// SPEAKS.
//
// Run it with:
//
//	WAKIL_CLAUDE_BINARY=$(which claude) go test ./internal/wakilcore/ \
//	    -run TestSetupTokenSpeaksOnlyToATerminal -v
//
// # What it proves
//
// `claude setup-token` writes **nothing at all** to a pipe and writes its
// console UI to a terminal. Measured 2026-09-23 against 2.1.280: 0 bytes
// on a pipe over twelve seconds, ~1.5 KB on a PTY including "This will
// guide you through long-lived (1-year) auth token setup" and "Opening
// browser to sign in…".
//
// That is why `MintProviderToken` spawns on a PTY. With a pipe the browser
// trip still completed and a real credential was still created at
// Anthropic — Wakil simply never saw the token, waited out its deadline,
// and left the operator on "Trip 2 of 2". A reading of the CLI's bundled
// JavaScript could not have told us this, and that reading is exactly what
// the two-trip design rested on (`provider-login-probe.md` §11.1).
func TestSetupTokenSpeaksOnlyToATerminal(t *testing.T) {
	claude := os.Getenv("WAKIL_CLAUDE_BINARY")
	if claude == "" {
		t.Skip("live: set WAKIL_CLAUDE_BINARY to a real claude to run this")
	}

	onPipe := runSetupTokenBriefly(t, claude, false)
	onTerminal := runSetupTokenBriefly(t, claude, true)

	t.Logf("pipe: %d bytes, terminal: %d bytes", len(onPipe), len(onTerminal))
	if strings.TrimSpace(onPipe) != "" {
		t.Errorf("a pipe produced output, so the PTY may no longer be needed: %q", onPipe)
	}
	if !strings.Contains(onTerminal, "auth token setup") {
		t.Errorf("a terminal did not produce the setup banner; the UI may have changed: %q",
			onTerminal)
	}
}

// runSetupTokenBriefly starts the flow, reads for a few seconds and kills
// it. The browser is shimmed away so no tab opens.
func runSetupTokenBriefly(t *testing.T, claude string, terminal bool) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	// The CLI opens the browser itself, unprompted. This records the URL
	// instead of opening it, which is also how the redirect_uri was read.
	if err := os.WriteFile(filepath.Join(bin, "open"),
		[]byte("#!/bin/sh\nprintf '%s' \"$*\" > "+dir+"/opened.txt\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, claude, "setup-token")
	cmd.Env = append(os.Environ(),
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"CLAUDE_CONFIG_DIR="+filepath.Join(dir, "cfg"))

	if terminal {
		out, _ := runOnPTY(cmd)
		return out
	}
	var buf strings.Builder
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	cmd.Stdin = nil
	_ = cmd.Run()
	return buf.String()
}
