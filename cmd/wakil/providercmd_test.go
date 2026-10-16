package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// TestProviderAddShareFlagRegistersASharedRecord confirms --share reaches
// AddProvider's new branch (Shared persists) and that the operator is
// told, at the moment of registration, the one limitation of sharing: the
// homing org keeps the pin. Discovering that later would mean discovering
// it as a bug, so the message must name the homing org.
func TestProviderAddShareFlagRegistersASharedRecord(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := filepath.Join(home, ".claude-shared")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, org := range []string{"initech", "personal"} {
		if err := wakilcore.CreateOrg(org, wakilcore.Org{}); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"main", "--kind", "claude-code", "--config-dir", cfg}, io.Discard); code != 0 {
		t.Fatalf("seed add: exit = %d", code)
	}

	t.Setenv("WAKIL_ORG", "personal")
	var stderr bytes.Buffer
	code := runProviderAdd([]string{
		"work", "--kind", "claude-code", "--config-dir", cfg, "--share",
	}, &stderr)
	if code != 0 {
		t.Fatalf("--share add: exit = %d, stderr = %q", code, stderr.String())
	}
	p, err := wakilcore.LoadProviderFor("personal", "work")
	if err != nil {
		t.Fatal(err)
	}
	if !p.Shared {
		t.Error("--share did not persist Shared=true")
	}
	// The operator must be told the pin did not move, at the moment they
	// create the binding — this is the one limitation of the feature and
	// discovering it later means discovering it as a bug.
	if !strings.Contains(stderr.String(), "initech") {
		t.Errorf("a --share add must name the org that still homes the dir; got %q", stderr.String())
	}
}

// TestProviderHomePrintsTheHomingOrgOnStdout confirms that, asked from
// the SHARING org, `provider home` still answers with the org that pinned
// WAKIL_ORG inside the directory — the only org a plain `claude` session
// started there will ever run as — and that it prints exactly one line on
// stdout and nothing on stderr.
func TestProviderHomePrintsTheHomingOrgOnStdout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := filepath.Join(home, ".claude-shared")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, org := range []string{"initech", "personal"} {
		if err := wakilcore.CreateOrg(org, wakilcore.Org{}); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"main", "--kind", "claude-code", "--config-dir", cfg}, io.Discard); code != 0 {
		t.Fatal("seed add failed")
	}
	t.Setenv("WAKIL_ORG", "personal")
	if code := runProviderAdd([]string{"work", "--kind", "claude-code", "--config-dir", cfg, "--share"}, io.Discard); code != 0 {
		t.Fatal("share add failed")
	}

	var stderr bytes.Buffer
	var code int
	stdout := captureStdout(t, func() {
		code = runProviderHome([]string{"work"}, &stderr)
	})
	if code != 0 {
		t.Fatalf("provider home: exit = %d, stderr = %q", code, stderr.String())
	}
	if stdout != "initech\n" {
		t.Errorf("provider home stdout = %q; want %q", stdout, "initech\n")
	}
	if stderr.String() != "" {
		t.Errorf("provider home wrote to stderr on success: %q", stderr.String())
	}
}

// TestProviderHomeOfAnUnsharedProviderIsItsOwnOrg confirms the baseline:
// a provider that never shared its configDir is its own home.
func TestProviderHomeOfAnUnsharedProviderIsItsOwnOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.CreateOrg("initech", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"main", "--kind", "claude-code", "--config-dir", cfg}, io.Discard); code != 0 {
		t.Fatal("seed add failed")
	}
	var stderr bytes.Buffer
	var code int
	stdout := captureStdout(t, func() {
		code = runProviderHome([]string{"main"}, &stderr)
	})
	if code != 0 {
		t.Fatalf("provider home: exit = %d", code)
	}
	if stdout != "initech\n" {
		t.Errorf("provider home stdout = %q; want %q", stdout, "initech\n")
	}
}

// TestProviderHomeMissingIDIsExitTwo confirms a bad invocation (no id
// given, nothing the operator did wrong except forget an argument) is
// exit 2, the "retype it" code, distinct from the exit 1 a failure while
// doing the work returns.
func TestProviderHomeMissingIDIsExitTwo(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	var code int
	captureStdout(t, func() {
		code = runProviderHome(nil, &stderr)
	})
	if code != 2 {
		t.Errorf("provider home with no id: exit = %d; want 2", code)
	}
	if !strings.Contains(stderr.String(), "missing <id>") {
		t.Errorf("stderr = %q; want it to name the missing argument", stderr.String())
	}
}

// TestProviderHomeOfANonClaudeCodeProviderIsExitOne confirms that asking
// for the home of a provider whose kind pins nothing (codex, local) is a
// failure encountered while doing the work, not a bad invocation — exit
// 1, not 2 — and that the message says why.
func TestProviderHomeOfANonClaudeCodeProviderIsExitOne(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := wakilcore.CreateOrg("initech", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"codex1", "--kind", "codex"}, io.Discard); code != 0 {
		t.Fatal("seed add failed")
	}
	var stderr bytes.Buffer
	var code int
	captureStdout(t, func() {
		code = runProviderHome([]string{"codex1"}, &stderr)
	})
	if code != 1 {
		t.Errorf("provider home of a codex provider: exit = %d; want 1", code)
	}
	if !strings.Contains(stderr.String(), "no configDir") {
		t.Errorf("stderr = %q; want it to say the provider has no configDir", stderr.String())
	}
}

// TestProviderAddRefusesShareOnACodexProviderAndSaysNothingAboutAPin is
// the CLI half of the fabricated-message defect.
//
// `--share` documented itself as "(--kind claude-code only)" and nothing
// enforced it. The record stored `"shared": true` with an empty
// ConfigDir, runProviderAdd's shared notice then asked ConfigDirHome(""),
// and the scan matched any record whose ConfigDir was also "" — every
// codex and local provider in any org. The operator was told:
//
//	this account is shared: alpha/c1 still pins WAKIL_ORG inside , so a
//	plain `claude` session started there runs as "alpha", not "zulu".
//
// An unrelated provider, an empty path, and a pin that does not exist.
// The fixture below is exactly that shape — a pre-existing local provider
// with no config dir, in an org that sorts first — so the message would
// be produced again if either defence were removed.
func TestProviderAddRefusesShareOnACodexProviderAndSaysNothingAboutAPin(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, org := range []string{"alpha", "zulu"} {
		if err := wakilcore.CreateOrg(org, wakilcore.Org{}); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WAKIL_ORG", "alpha")
	if code := runProviderAdd([]string{"c1", "--kind", "local"}, io.Discard); code != 0 {
		t.Fatalf("seed add: exit = %d", code)
	}

	t.Setenv("WAKIL_ORG", "zulu")
	var stderr bytes.Buffer
	if code := runProviderAdd([]string{"c2", "--kind", "codex", "--share"}, &stderr); code == 0 {
		t.Fatalf("exit = 0; --share must be refused on a kind with no config dir. stderr = %q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "claude-code") {
		t.Errorf("the refusal must say which kind --share applies to; got %q", stderr.String())
	}
	for _, unwanted := range []string{"pins WAKIL_ORG", "alpha/c1"} {
		if strings.Contains(stderr.String(), unwanted) {
			t.Errorf("stderr must not claim anything about a pin; found %q in %q", unwanted, stderr.String())
		}
	}
	if _, err := wakilcore.LoadProviderFor("zulu", "c2"); err == nil {
		t.Error("a refused provider add still wrote a record")
	}
}
