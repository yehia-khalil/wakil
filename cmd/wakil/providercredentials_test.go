package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// mustOrgWithProvider creates org and registers a claude-code provider
// under it with the given config dir and claude path, failing the test
// on any error. It is the shared setup for `provider credentials` tests:
// they all need a real, loadable provider record before exercising the
// command that reads it back.
func mustOrgWithProvider(t *testing.T, org, id, configDir, claudePath string) {
	t.Helper()
	if err := wakilcore.CreateOrg(org, wakilcore.Org{}); err != nil {
		t.Fatalf("CreateOrg(%q): %v", org, err)
	}
	if err := wakilcore.AddProvider(org, wakilcore.Provider{
		ID:         id,
		Kind:       wakilcore.ProviderKindClaudeCode,
		ConfigDir:  configDir,
		ClaudePath: claudePath,
	}); err != nil {
		t.Fatalf("AddProvider(%q, %q): %v", org, id, err)
	}
}

func TestProviderCredentialsEmitsJSON(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := t.TempDir()
	mustOrgWithProvider(t, "acme", "main", configDir, "/opt/bin/claude")

	var stdout, stderr bytes.Buffer
	read := func(ref string) (string, error) {
		if ref != "provider:main" {
			t.Fatalf("read ref = %q, want provider:main", ref)
		}
		return "sk-tok", nil
	}
	code := run([]string{"--org", "acme", "provider", "credentials", "main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr.String())
	}
	var got struct {
		ConfigDir, ClaudePath, OAuthToken string
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v (%q)", err, stdout.String())
	}
	// AddProvider stores the symlink-RESOLVED configDir (see
	// internal/wakilcore/provider.go), and on macOS t.TempDir() sits under
	// /var, which is a symlink to /private/var. Comparing against the
	// unresolved configDir would fail here for that reason, not because of
	// anything runProviderCredentials got wrong — the same accommodation
	// TestProvidersRoundTripAndSort makes in internal/wakilcore/provider_test.go.
	wantConfigDir, err := filepath.EvalSymlinks(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if got.ConfigDir != wantConfigDir || got.ClaudePath != "/opt/bin/claude" || got.OAuthToken != "sk-tok" {
		t.Fatalf("got %+v, want configDir %q", got, wantConfigDir)
	}
}

func TestProviderCredentialsRefusals(t *testing.T) {
	configDir := t.TempDir()
	cases := []struct {
		name, provider, wantSubstring string
		setup                         func(t *testing.T)
		read                          secretReader
	}{
		{
			// Refuses at CurrentOrg/LoadProviderFor lookup, well before the
			// read. failingReader(t) pins that: if a future change moved
			// the read earlier than this check, the fatal inside
			// failingReader would catch it immediately.
			name: "unregistered id", provider: "ghost",
			wantSubstring: "wakil provider add",
			setup:         func(t *testing.T) { mustOrgWithProvider(t, "acme", "main", configDir, "/c") },
			read:          failingReader(t),
		},
		{
			// Refuses at the os.Stat(configDir) check, before the read.
			// Same rationale as "unregistered id" above.
			name: "config dir missing", provider: "main",
			wantSubstring: "does not exist",
			setup: func(t *testing.T) {
				dir := t.TempDir()
				mustOrgWithProvider(t, "acme", "main", dir, "/c")
				if err := os.RemoveAll(dir); err != nil {
					t.Fatalf("RemoveAll: %v", err)
				}
			},
			read: failingReader(t),
		},
		{
			// This is the one case that legitimately reaches the read: every
			// earlier validation (org, provider lookup, kind, config-dir
			// existence) passes, and only the Keychain lookup itself fails.
			// That is why this case, alone, keeps an erroring fake reader
			// instead of failingReader(t) — the difference between the two
			// is the whole point of this table.
			name: "no token stored", provider: "main",
			wantSubstring: "wakil secrets set provider:main",
			setup:         func(t *testing.T) { mustOrgWithProvider(t, "acme", "main", configDir, "/c") },
			read: func(string) (string, error) {
				return "", wakilcore.UserError("no credential stored for ref provider:main in org acme" +
					" — store it with: WAKIL_ORG=acme wakil secrets set provider:main")
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			tc.setup(t)
			var stdout, stderr bytes.Buffer
			code := run([]string{"--org", "acme", "provider", "credentials", tc.provider},
				strings.NewReader(""), &stdout, &stderr, failingStore(t), tc.read)
			if code != 2 {
				t.Fatalf("exit = %d, want 2", code)
			}
			if !strings.Contains(stderr.String(), tc.wantSubstring) {
				t.Fatalf("stderr = %q, want it to name %q", stderr.String(), tc.wantSubstring)
			}
			if stdout.Len() != 0 {
				t.Fatalf("stdout = %q, want empty on refusal", stdout.String())
			}
		})
	}
}

// TestProviderCredentialsNeverPrintsTheTokenOnFailure guards against a
// future refusal path that builds its message by interpolating everything
// the command knows, token included. In the current design this scenario
// (config dir removed after registration) refuses at the os.Stat check,
// strictly before read is called, so the fake reader here is never even
// invoked — this test cannot catch a leak from that call, only from a
// hypothetical later one. TestProviderCredentialsRefusals/"config dir
// missing" pins the actual guarantee for this path: that the read is never
// reached at all. Keep this test as a refactor canary regardless.
func TestProviderCredentialsNeverPrintsTheTokenOnFailure(t *testing.T) {
	const token = "sk-do-not-print-me"
	t.Setenv("HOME", t.TempDir())
	// A config dir that exists at registration and is gone by lookup time
	// is the refusal most likely to be built by interpolating everything
	// the command knows, token included.
	configDir := t.TempDir()
	mustOrgWithProvider(t, "acme", "main", configDir, "/c")
	if err := os.RemoveAll(configDir); err != nil {
		t.Fatalf("RemoveAll: %v", err)
	}
	var stdout, stderr bytes.Buffer
	read := func(string) (string, error) { return token, nil }
	code := run([]string{"--org", "acme", "provider", "credentials", "main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if strings.Contains(stderr.String()+stdout.String(), token) {
		t.Fatalf("the token reached output: stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

// TestProviderCredentialsStripsWhitespaceFromTheToken pins the repair for
// the failure that cost an hour on the 2b-vi acceptance walk, 2026-09-11:
// `claude setup-token` printed a 108-character token across three terminal
// lines, a mouse selection captured the wraps, and the stored value carried
// two newlines and two spaces in the MIDDLE of the string. The symptom was
// `401 Invalid bearer token` with nothing naming the cause.
//
// An OAuth token cannot contain whitespace, so stripping it here can only
// restore the value — which is why this is done for a provider token and
// deliberately NOT in SecretSet, where a database password containing a
// space is an ordinary thing to store.
func TestProviderCredentialsStripsWhitespaceFromTheToken(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configDir := t.TempDir()
	mustOrgWithProvider(t, "acme", "main", configDir, "/c")

	var stdout, stderr bytes.Buffer
	// The exact shape the walk produced: interior newlines AND spaces.
	read := func(string) (string, error) { return "sk-ant-oat0-AAA\nBBB CCC\nDDD", nil }
	code := run([]string{"--org", "acme", "provider", "credentials", "main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr.String())
	}
	var got struct{ OAuthToken string }
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v", err)
	}
	if want := "sk-ant-oat0-AAABBBCCCDDD"; got.OAuthToken != want {
		t.Fatalf("OAuthToken = %q, want %q", got.OAuthToken, want)
	}
}

// TestProviderCredentialsRefusesAnAllWhitespaceToken is the boundary of the
// strip above: removing whitespace must not turn a useless stored value into
// an empty string that gets handed to `claude` as if it were a credential.
func TestProviderCredentialsRefusesAnAllWhitespaceToken(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configDir := t.TempDir()
	mustOrgWithProvider(t, "acme", "main", configDir, "/c")

	var stdout, stderr bytes.Buffer
	read := func(string) (string, error) { return " \n\t ", nil }
	code := run([]string{"--org", "acme", "provider", "credentials", "main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "wakil secrets set provider:main") {
		t.Fatalf("stderr = %q, want it to name the re-store command", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want empty on refusal", stdout.String())
	}
}

func TestProviderCredentialsInheritsClaudePathForASharedRecord(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configDir := t.TempDir()
	mustOrgWithProvider(t, "home", "main", configDir, "/opt/bin/claude")
	if err := wakilcore.CreateOrg("sharer", wakilcore.Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	// No ClaudePath: the whole point is that a share does not repeat one.
	if err := wakilcore.AddProvider("sharer", wakilcore.Provider{
		ID: "home-main", Kind: wakilcore.ProviderKindClaudeCode,
		ConfigDir: configDir, Shared: true,
	}); err != nil {
		t.Fatalf("AddProvider share: %v", err)
	}

	var stdout, stderr bytes.Buffer
	read := func(string) (string, error) { return "sk-tok", nil }
	code := run([]string{"--org", "sharer", "provider", "credentials", "home-main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr.String())
	}
	var got struct{ ClaudePath string }
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v (%q)", err, stdout.String())
	}
	if got.ClaudePath != "/opt/bin/claude" {
		t.Fatalf("claudePath = %q; a shared record must inherit the homing record's binary", got.ClaudePath)
	}
}
