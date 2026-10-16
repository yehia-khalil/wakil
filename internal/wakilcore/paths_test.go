package wakilcore

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestCurrentOrgRequiresWakilOrg(t *testing.T) {
	t.Setenv("WAKIL_ORG", "")
	t.Setenv("CLAUDE_CONFIG_DIR", "/home/someone/.claude-initech")

	got, err := CurrentOrg()
	if err == nil {
		t.Fatalf("CurrentOrg() = %q, nil; want an error when WAKIL_ORG is unset", got)
	}
	if !strings.Contains(err.Error(), "WAKIL_ORG") {
		t.Errorf("error must name the variable the operator has to set; got %q", err)
	}
	// The whole point: CLAUDE_CONFIG_DIR must NOT be consulted as a fallback.
	if strings.Contains(err.Error(), "initech") {
		t.Errorf("CurrentOrg fell back to CLAUDE_CONFIG_DIR; got %q", err)
	}
}

func TestCurrentOrgRejectsUnusableIDs(t *testing.T) {
	for _, bad := range []string{"/", "..", ".", "-x", " x", "a:b", "", "a/b"} {
		t.Run(strconv.Quote(bad), func(t *testing.T) {
			t.Setenv("WAKIL_ORG", bad)
			if got, err := CurrentOrg(); err == nil {
				t.Fatalf("CurrentOrg() = %q, nil; want an error for org %q", got, bad)
			}
		})
	}
}

func TestCurrentOrgAcceptsFreeFormNames(t *testing.T) {
	for _, ok := range []string{"initech", "client-a", "side.project", "A_b", "umbrella"} {
		t.Run(ok, func(t *testing.T) {
			t.Setenv("WAKIL_ORG", ok)
			got, err := CurrentOrg()
			if err != nil {
				t.Fatalf("CurrentOrg() error = %v; want %q accepted", err, ok)
			}
			if got != ok {
				t.Errorf("CurrentOrg() = %q; want %q — the value is used verbatim, never derived", got, ok)
			}
		})
	}
}

func TestOrgDirRefusesUnregisteredOrg(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "umbrela")

	got, err := OrgDir()
	if err == nil {
		t.Fatalf("OrgDir() = %q, nil; want a refusal for an unregistered org", got)
	}
	if !strings.Contains(err.Error(), "umbrela") || !strings.Contains(err.Error(), "wakil org create") {
		t.Errorf("the refusal must name the org and the command that fixes it; got %q", err)
	}
}

func TestOrgDirAcceptsRegisteredOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	want := filepath.Join(home, ".wakil", "orgs", "initech")
	if err := os.MkdirAll(want, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := OrgDir()
	if err != nil {
		t.Fatalf("OrgDir() error = %v", err)
	}
	if got != want {
		t.Errorf("OrgDir() = %q; want %q", got, want)
	}
}

func TestWakilDir_Error(t *testing.T) {
	// Test that WakilDir returns error when HOME is unset and does not return a relative path
	t.Setenv("HOME", "")

	got, err := WakilDir()
	if err == nil {
		t.Errorf("WakilDir() error = nil, want non-nil error")
	}
	// Verify we don't get a relative path (which would silently fail during operation)
	if got != "" {
		t.Errorf("WakilDir() = %q, want empty string on error", got)
	}
	// Verify it's not a relative path like ".wakil"
	if filepath.IsAbs(got) {
		t.Errorf("WakilDir() returned absolute path on error: %q", got)
	}
}
