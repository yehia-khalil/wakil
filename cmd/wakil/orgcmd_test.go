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

// captureStdout redirects os.Stdout for the duration of fn and returns
// everything written to it. run() DOES take a stdout parameter now (org
// list and provider list use it — Finding 2 of Task 10's review), but
// runProviderConfigDir still writes to os.Stdout directly rather than
// through that parameter (see its own doc comment for why), so this is
// the only way to observe ITS output from a test.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	fn()
	if err := w.Close(); err != nil {
		t.Fatalf("close pipe writer: %v", err)
	}
	os.Stdout = old
	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read pipe: %v", err)
	}
	return string(data)
}

// writeProjectFile writes a minimal, valid project.json declaring org and
// returns its absolute path.
func writeProjectFile(t *testing.T, dir, org, name string) string {
	t.Helper()
	path := filepath.Join(dir, "project.json")
	body := `{"name":"` + name + `","org":"` + org + `"}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}
	return path
}

// ---------------------------------------------------------------------
// global --org flag and dispatch (task brief Step 1, verbatim)
// ---------------------------------------------------------------------

func TestGlobalOrgFlagSetsTheOrgForTheCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")

	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	if code := run([]string{"--org", "initech", "provider", "list"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("--org was not honoured: exit = %d, stderr = %q", code, stderr.String())
	}
}

// TestOrgCreateRefusesBadJiraBaseWithExitCode2 also pins finding 5 of the
// final review: the rejection must name the knob the operator actually
// used (--jira-base, a CLI flag) rather than WAKIL_JIRA_BASE, an
// environment variable this invocation never touched. normalizeJiraBase
// used to hardcode "WAKIL_JIRA_BASE must ..." in every message regardless
// of caller, which told an operator running `org create --jira-base` to
// go fix an environment variable they never set.
func TestOrgCreateRefusesBadJiraBaseWithExitCode2(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	code := run([]string{"org", "create", "initech", "--jira-base", "http://insecure"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Errorf("exit = %d; want 2 (operator can fix by retyping)", code)
	}
	out := stderr.String()
	if !strings.Contains(out, "https") {
		t.Errorf("stderr = %q; want it to say what is wrong", out)
	}
	if !strings.Contains(out, "--jira-base") {
		t.Errorf("stderr = %q; want it to name the flag the operator actually gave", out)
	}
	if strings.Contains(out, "WAKIL_JIRA_BASE") {
		t.Errorf("stderr = %q; must not blame an environment variable this invocation never set", out)
	}
}

func TestUnknownSubcommandStillExits2WithUsage(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	if code := run([]string{"frobnicate"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 2 {
		t.Errorf("exit = %d; want 2", code)
	}
	if !strings.Contains(stderr.String(), "usage:") {
		t.Errorf("stderr must include usage; got %q", stderr.String())
	}
}

// ---------------------------------------------------------------------
// wakil org
// ---------------------------------------------------------------------

func TestOrgCreateListAndRm(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "")
	var stderr bytes.Buffer

	if code := run([]string{"org", "create", "initech", "--display", "Two Forty Seven"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}

	// `org list` writes its rows to STDOUT (Finding 2: they are data a
	// caller like register-provider.sh consumes, not a diagnostic), so
	// this asserts against a dedicated stdout buffer, not stderr.
	stderr.Reset()
	var stdout bytes.Buffer
	if code := run([]string{"org", "list"}, strings.NewReader(""), &stdout, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org list: exit = %d, stderr = %q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "initech") {
		t.Fatalf("org list stdout = %q, want it to name %q", stdout.String(), "initech")
	}
	if stderr.String() != "" {
		t.Fatalf("org list stderr = %q, want nothing on a successful non-empty list", stderr.String())
	}

	// A non-empty org (it holds no providers or projects yet, so this is
	// really just proving the round trip) is removable without --force.
	stderr.Reset()
	if code := run([]string{"org", "rm", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org rm: exit = %d, stderr = %q", code, stderr.String())
	}

	stderr.Reset()
	stdout.Reset()
	if code := run([]string{"org", "list"}, strings.NewReader(""), &stdout, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org list after rm: exit = %d, stderr = %q", code, stderr.String())
	}
	if strings.Contains(stdout.String(), "initech") {
		t.Fatalf("org list after rm stdout = %q, want %q gone", stdout.String(), "initech")
	}
	// An empty registry is a DIAGNOSTIC ("no orgs registered"), not a row
	// of data, so it belongs on stderr and stdout must stay empty.
	if stdout.String() != "" {
		t.Fatalf("org list after rm stdout = %q, want empty (the empty-registry notice belongs on stderr)", stdout.String())
	}
	if !strings.Contains(stderr.String(), "no orgs registered") {
		t.Fatalf("org list after rm stderr = %q, want the empty-registry notice", stderr.String())
	}
}

// TestOrgListAndProviderListWriteRowsToStdoutNotStderr is Finding 2 of
// Task 10's review, pinned directly rather than only incidentally through
// the round-trip tests above: `org list` and `provider list` exist so a
// caller like register-provider.sh can consume their rows, and a
// diagnostic sharing that stream would be silently parsed as data. Rows
// go to stdout; everything else (here, the "no providers registered"
// notice for the org's still-empty provider registry) stays on stderr.
func TestOrgListAndProviderListWriteRowsToStdoutNotStderr(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}

	stderr.Reset()
	var orgOut bytes.Buffer
	if code := run([]string{"org", "list"}, strings.NewReader(""), &orgOut, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org list: exit = %d, stderr = %q", code, stderr.String())
	}
	if orgOut.String() != "initech\n" {
		t.Fatalf("org list stdout = %q, want exactly %q", orgOut.String(), "initech\n")
	}
	if stderr.String() != "" {
		t.Fatalf("org list stderr = %q, want empty", stderr.String())
	}

	// The org's provider registry is still empty, so `provider list`'s
	// only output is the diagnostic — which must land on stderr, leaving
	// stdout with nothing for a caller to misparse as a row.
	stderr.Reset()
	var provOut bytes.Buffer
	if code := run([]string{"--org", "initech", "provider", "list"}, strings.NewReader(""), &provOut, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider list: exit = %d, stderr = %q", code, stderr.String())
	}
	if provOut.String() != "" {
		t.Fatalf("provider list stdout = %q, want empty (the empty-registry notice is a diagnostic)", provOut.String())
	}
	if !strings.Contains(stderr.String(), "no providers registered") {
		t.Fatalf("provider list stderr = %q, want the empty-registry notice", stderr.String())
	}
}

func TestOrgCreateRefusesDuplicate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("first create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2 (retype a different org name)", code)
	}
	if !strings.Contains(stderr.String(), "already exists") {
		t.Fatalf("stderr = %q, want it to say the org already exists", stderr.String())
	}
}

// TestOrgSetMergesFieldsWithoutErasingOthers pins runOrgSet's merge
// behaviour: setting one field must not blank out a field set earlier.
// Deleting the fs.Visit merge in runOrgSet (falling back to a bare
// wakilcore.Org{} overwrite) makes this fail, because DisplayName would
// come back empty after the --jira-base-only update.
func TestOrgSetMergesFieldsWithoutErasingOthers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech", "--display", "Two Forty Seven"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	if code := run([]string{"org", "set", "initech", "--jira-base", "https://acme.atlassian.net"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("set: exit = %d, stderr = %q", code, stderr.String())
	}

	got, err := wakilcore.LoadOrgFor("initech")
	if err != nil {
		t.Fatalf("LoadOrgFor: %v", err)
	}
	if got.DisplayName != "Two Forty Seven" {
		t.Fatalf("DisplayName = %q, want it preserved from `org create`", got.DisplayName)
	}
	if got.JiraBase != "https://acme.atlassian.net" {
		t.Fatalf("JiraBase = %q, want the value just set", got.JiraBase)
	}
}

func TestOrgSetRefusesUnregisteredOrg(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	code := run([]string{"org", "set", "nosuch", "--display", "x"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "not registered") {
		t.Fatalf("stderr = %q, want it to say the org is not registered", stderr.String())
	}
}

func TestOrgRmRefusesNonEmptyWithoutForce(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// Scopes the leak from the "--org initech" flag below (applyOrgFlag sets
	// WAKIL_ORG via os.Setenv, not t.Setenv) to this test — see finding
	// 10 of the final review: without a prior t.Setenv on this exact key,
	// nothing restores WAKIL_ORG when this test ends, and it leaks into
	// whichever test runs next under -shuffle=on.
	t.Setenv("WAKIL_ORG", "")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	dir := t.TempDir()
	if code := run([]string{"--org", "initech", "provider", "add", "primary", "--kind", "claude-code", "--config-dir", dir}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider add: exit = %d, stderr = %q", code, stderr.String())
	}

	stderr.Reset()
	code := run([]string{"org", "rm", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2 (retype with --force)", code)
	}
	if !strings.Contains(stderr.String(), "--force") {
		t.Fatalf("stderr = %q, want it to mention --force", stderr.String())
	}

	stderr.Reset()
	if code := run([]string{"org", "rm", "initech", "--force"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("forced rm: exit = %d, stderr = %q", code, stderr.String())
	}
}

func TestOrgCreateAndRmMissingArgExitsTwo(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, args := range [][]string{{"org", "create"}, {"org", "set"}, {"org", "rm"}, {"org"}, {"org", "frobnicate"}} {
		var stderr bytes.Buffer
		if code := run(args, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 2 {
			t.Errorf("run(%q) = %d, want 2 (stderr: %s)", args, code, stderr.String())
		}
	}
}

// ---------------------------------------------------------------------
// wakil provider
// ---------------------------------------------------------------------

func TestProviderAddClaudeCodeAndConfigDir(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}

	dir := t.TempDir()
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}

	stderr.Reset()
	if code := run([]string{"provider", "add", "primary", "--kind", "claude-code", "--config-dir", dir, "--label", "Main account"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider add: exit = %d, stderr = %q", code, stderr.String())
	}

	// provider list names it, on STDOUT — Finding 2: a provider row is
	// data a caller like register-provider.sh consumes, not a diagnostic.
	stderr.Reset()
	var providerListOut bytes.Buffer
	if code := run([]string{"provider", "list"}, strings.NewReader(""), &providerListOut, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider list: exit = %d, stderr = %q", code, stderr.String())
	}
	if !strings.Contains(providerListOut.String(), "primary") || !strings.Contains(providerListOut.String(), "claude-code") {
		t.Fatalf("provider list stdout = %q, want it to name the provider and its kind", providerListOut.String())
	}
	if stderr.String() != "" {
		t.Fatalf("provider list stderr = %q, want nothing on a successful non-empty list", stderr.String())
	}

	// provider config-dir prints ONLY the resolved directory to stdout,
	// nothing else, with exit 0.
	var stdout string
	var errb bytes.Buffer
	var code int
	stdout = captureStdout(t, func() {
		code = run([]string{"provider", "config-dir", "primary"}, strings.NewReader(""), io.Discard, &errb, failingStore(t), failingReader(t))
	})
	if code != 0 {
		t.Fatalf("provider config-dir: exit = %d, stderr = %q", code, errb.String())
	}
	if stdout != resolved+"\n" {
		t.Fatalf("stdout = %q, want exactly %q", stdout, resolved+"\n")
	}
	if errb.String() != "" {
		t.Fatalf("stderr = %q, want empty on a successful config-dir", errb.String())
	}

	// provider rm removes it.
	stderr.Reset()
	if code := run([]string{"provider", "rm", "primary"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider rm: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	providerListOut.Reset()
	if code := run([]string{"provider", "list"}, strings.NewReader(""), &providerListOut, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider list after rm: exit = %d, stderr = %q", code, stderr.String())
	}
	if strings.Contains(providerListOut.String(), "primary") {
		t.Fatalf("provider list after rm stdout = %q, want %q gone", providerListOut.String(), "primary")
	}
	// An empty org's provider list is a DIAGNOSTIC, not a row of data, so
	// it belongs on stderr and stdout must stay empty.
	if providerListOut.String() != "" {
		t.Fatalf("provider list after rm stdout = %q, want empty (the empty-list notice belongs on stderr)", providerListOut.String())
	}
	if !strings.Contains(stderr.String(), "no providers registered") {
		t.Fatalf("provider list after rm stderr = %q, want the empty-list notice", stderr.String())
	}
}

// TestProviderConfigDirNoConfigDirExitsOne pins Decision 4: a kind with no
// configDir is not a retypeable mistake, so it is 1, not 2, and — just as
// important — nothing is printed to stdout on that path. Deleting the
// p.ConfigDir == "" check in runProviderConfigDir would let execution
// fall through to fmt.Println(p.ConfigDir) with an empty string, printing
// a bare newline to stdout and exiting 0 — which a shell script reading
// this command's stdout (Task 10's register-provider.sh) would read as a
// real, empty configDir rather than "not configured".
func TestProviderConfigDirNoConfigDirExitsOne(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	if code := run([]string{"provider", "add", "backup", "--kind", "codex"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider add: exit = %d, stderr = %q", code, stderr.String())
	}

	var errb bytes.Buffer
	var code int
	stdout := captureStdout(t, func() {
		code = run([]string{"provider", "config-dir", "backup"}, strings.NewReader(""), io.Discard, &errb, failingStore(t), failingReader(t))
	})
	if code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want nothing printed for a provider with no configDir", stdout)
	}
	if !strings.Contains(errb.String(), "no configDir") {
		t.Fatalf("stderr = %q, want it to explain there is no configDir", errb.String())
	}
}

func TestProviderConfigDirUnknownIDExitsTwo(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	var errb bytes.Buffer
	var code int
	stdout := captureStdout(t, func() {
		code = run([]string{"provider", "config-dir", "nosuch"}, strings.NewReader(""), io.Discard, &errb, failingStore(t), failingReader(t))
	})
	if code != 2 {
		t.Fatalf("exit = %d, want 2 (retype a registered provider id)", code)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want nothing printed for an unknown provider", stdout)
	}
}

// TestProviderAddCodexPrintsClientInstructions pins Decision 6: a codex
// or local provider is recorded but not automated, and the command must
// say so plainly and print the exact environment the operator needs.
func TestProviderAddCodexPrintsClientInstructions(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}

	stderr.Reset()
	if code := run([]string{"provider", "add", "codex1", "--kind", "codex"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider add: exit = %d, stderr = %q", code, stderr.String())
	}
	out := stderr.String()
	if !strings.Contains(out, "does not register") {
		t.Fatalf("stderr = %q, want it to say plainly that wakil does not automate this", out)
	}
	if !strings.Contains(out, "WAKIL_ORG=initech") {
		t.Fatalf("stderr = %q, want WAKIL_ORG=initech", out)
	}
	if !strings.Contains(out, "WAKIL_PROVIDER=codex1") {
		t.Fatalf("stderr = %q, want WAKIL_PROVIDER=codex1", out)
	}
	for _, bin := range []string{"wakil-ctx", "wakil-db", "wakil-pm", "wakil-http", "wakil-recall", "wakil-git"} {
		if !strings.Contains(out, bin) {
			t.Fatalf("stderr = %q, want it to name the binary %q", out, bin)
		}
	}
}

func TestProviderAddRejectsBadKindWithExitCode2(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	code := run([]string{"provider", "add", "x", "--kind", "windows"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "unknown provider kind") {
		t.Fatalf("stderr = %q, want it to name the bad kind", stderr.String())
	}
}

func TestProviderCommandsRequireCurrentOrg(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "")
	for _, args := range [][]string{{"provider", "list"}, {"provider", "add", "x", "--kind", "codex"}, {"provider", "rm", "x"}, {"provider", "config-dir", "x"}} {
		var stderr bytes.Buffer
		if code := run(args, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 2 {
			t.Errorf("run(%q) = %d, want 2 (WAKIL_ORG unset)", args, code)
		}
		if !strings.Contains(stderr.String(), "WAKIL_ORG") {
			t.Errorf("run(%q) stderr = %q, want it to mention WAKIL_ORG", args, stderr.String())
		}
	}
}

// ---------------------------------------------------------------------
// wakil project
// ---------------------------------------------------------------------

// TestProjectAddRefusesOrgMismatch pins the mutation-tested behaviour:
// project add must load the project file and compare its declared org
// against the current org BEFORE writing anything to the registry.
func TestProjectAddRefusesOrgMismatch(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}

	projDir := t.TempDir()
	path := writeProjectFile(t, projDir, "umbrella", "booking")

	stderr.Reset()
	code := run([]string{"project", "add", "booking", "--path", path}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2 (stderr: %s)", code, stderr.String())
	}
	out := stderr.String()
	if !strings.Contains(out, "initech") || !strings.Contains(out, "umbrella") {
		t.Fatalf("stderr = %q, want it to name both the current org and the project's declared org", out)
	}

	// Nothing was written to the registry.
	reg, err := wakilcore.LoadRegistryFor("initech")
	if err != nil {
		t.Fatalf("LoadRegistryFor: %v", err)
	}
	if len(reg) != 0 {
		t.Fatalf("registry = %+v, want nothing written on a refused add", reg)
	}
}

func TestProjectAddListAndRm(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	// --provider is validated for existence now (finding 13 of the final
	// review), so "primary" must actually be registered before a project
	// can name it.
	stderr.Reset()
	if code := run([]string{"provider", "add", "primary", "--kind", "local"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider add: exit = %d, stderr = %q", code, stderr.String())
	}

	projDir := t.TempDir()
	path := writeProjectFile(t, projDir, "initech", "booking")

	stderr.Reset()
	if code := run([]string{"project", "add", "booking", "--path", path, "--provider", "primary"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("project add: exit = %d, stderr = %q", code, stderr.String())
	}

	// `project list` writes its rows to STDOUT (finding 12 of the final
	// review — the same treatment `org list` and `provider list` already
	// got), so this asserts against a dedicated stdout buffer.
	stderr.Reset()
	var stdout bytes.Buffer
	if code := run([]string{"project", "list"}, strings.NewReader(""), &stdout, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("project list: exit = %d, stderr = %q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "booking") || !strings.Contains(stdout.String(), path) {
		t.Fatalf("project list stdout = %q, want the name and path", stdout.String())
	}
	if stderr.String() != "" {
		t.Fatalf("project list stderr = %q, want nothing on a successful non-empty list", stderr.String())
	}

	stderr.Reset()
	if code := run([]string{"project", "rm", "booking"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("project rm: exit = %d, stderr = %q", code, stderr.String())
	}
	reg, err := wakilcore.LoadRegistryFor("initech")
	if err != nil {
		t.Fatalf("LoadRegistryFor: %v", err)
	}
	if len(reg) != 0 {
		t.Fatalf("registry = %+v, want empty after rm", reg)
	}
}

// TestProjectListWritesRowsToStdoutNotStderr pins finding 12 of the final
// review directly, the same way TestOrgListAndProviderListWriteRowsToStdoutNotStderr
// pins it for `org list` and `provider list`: an empty registry's "no
// projects registered" notice is a DIAGNOSTIC, not a row, and must stay
// off stdout so a caller piping this command's stdout never mistakes it
// for data.
func TestProjectListWritesRowsToStdoutNotStderr(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}

	stderr.Reset()
	var stdout bytes.Buffer
	if code := run([]string{"project", "list"}, strings.NewReader(""), &stdout, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("project list: exit = %d, stderr = %q", code, stderr.String())
	}
	if stdout.String() != "" {
		t.Fatalf("project list stdout = %q, want empty (the empty-registry notice belongs on stderr)", stdout.String())
	}
	if !strings.Contains(stderr.String(), "no projects registered") {
		t.Fatalf("project list stderr = %q, want the empty-registry notice", stderr.String())
	}
}

// TestProjectAddRejectsUnregisteredProvider pins finding 13 of the final
// review: --provider is optional, but when given it must name a
// provider actually registered under the org, for the same reason
// org.json's defaultProvider is checked (finding 2) — a typo used to be
// accepted silently and surface only much later.
func TestProjectAddRejectsUnregisteredProvider(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	path := writeProjectFile(t, t.TempDir(), "initech", "booking")

	stderr.Reset()
	code := run([]string{"project", "add", "booking", "--path", path, "--provider", "nosuch"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2 (retype a registered provider id): stderr = %q", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "nosuch") {
		t.Fatalf("stderr = %q, want it to name the unregistered provider", stderr.String())
	}

	reg, err := wakilcore.LoadRegistryFor("initech")
	if err != nil {
		t.Fatalf("LoadRegistryFor: %v", err)
	}
	if len(reg) != 0 {
		t.Fatalf("registry = %+v, want nothing written on a refused add", reg)
	}
}

func TestProjectAddRefusesDuplicateName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	path := writeProjectFile(t, t.TempDir(), "initech", "booking")
	stderr.Reset()
	if code := run([]string{"project", "add", "booking", "--path", path}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("first add: exit = %d, stderr = %q", code, stderr.String())
	}

	otherPath := writeProjectFile(t, t.TempDir(), "initech", "booking2")
	stderr.Reset()
	code := run([]string{"project", "add", "booking", "--path", otherPath}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "already exists") {
		t.Fatalf("stderr = %q, want it to say the name is taken", stderr.String())
	}

	// The original entry must survive untouched.
	reg, err := wakilcore.LoadRegistryFor("initech")
	if err != nil {
		t.Fatalf("LoadRegistryFor: %v", err)
	}
	if reg["booking"].Path != path {
		t.Fatalf("registry[booking].Path = %q, want the original %q preserved", reg["booking"].Path, path)
	}
}

func TestProjectAddRequiresAbsolutePath(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	code := run([]string{"project", "add", "booking", "--path", "relative/project.json"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "must be absolute") {
		t.Fatalf("stderr = %q, want it to say the path must be absolute", stderr.String())
	}
}

func TestProjectAddRequiresPathFlag(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	code := run([]string{"project", "add", "booking"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "--path") {
		t.Fatalf("stderr = %q, want it to name the missing flag", stderr.String())
	}
}

func TestProjectRmRefusesUnknownName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	code := run([]string{"project", "rm", "nosuch"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t))
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "no project") {
		t.Fatalf("stderr = %q, want it to say the name is not registered", stderr.String())
	}
}

func TestProviderAddLocalWithBaseURLAndServes(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org create: exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	if code := run([]string{"provider", "add", "qwen", "--kind", "local", "--base-url", "http://127.0.0.1:8012", "--serves", "infill,respond"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("provider add: exit = %d, stderr = %q", code, stderr.String())
	}
	var out bytes.Buffer
	stderr.Reset()
	if code := run([]string{"provider", "list"}, strings.NewReader(""), &out, &stderr, failingStore(t), failingReader(t)); code != 0 || !strings.Contains(out.String()+stderr.String(), "qwen") {
		t.Fatalf("provider list: exit = %d, out = %q, stderr = %q", code, out.String(), stderr.String())
	}
}

// TestOrgRmNamesTheBrowserStoreItLeaves pins final review I6: an organisation's browser logins
// live in a WebKit store under ~/Library/WebKit that only Wakil can delete, by the id in
// browser/profile.json. `org rm` deletes that id with the directory, so it says the store stays,
// names it, and says how to clear it first. An org with no browser profile says nothing more.
func TestOrgRmNamesTheBrowserStoreItLeaves(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	var stderr bytes.Buffer
	for _, org := range []string{"initech", "globex"} {
		if code := run([]string{"org", "create", org}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
			t.Fatalf("org create %s: exit = %d, stderr = %q", org, code, stderr.String())
		}
	}
	browser := filepath.Join(home, ".wakil", "orgs", "initech", "browser")
	if err := os.MkdirAll(browser, 0o755); err != nil {
		t.Fatal(err)
	}
	const id = "6B29FC40-CA47-1067-B31D-00DD010662DA"
	if err := os.WriteFile(filepath.Join(browser, "profile.json"), []byte(`{"identifier":"`+id+`"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	stderr.Reset()
	if code := run([]string{"org", "rm", "initech"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org rm: exit = %d, stderr = %q", code, stderr.String())
	}
	for _, want := range []string{`removed org "initech"`, id, "~/Library/WebKit", "Settings → Browser"} {
		if !strings.Contains(stderr.String(), want) {
			t.Fatalf("org rm stderr = %q, want it to contain %q", stderr.String(), want)
		}
	}

	stderr.Reset()
	if code := run([]string{"org", "rm", "globex"}, strings.NewReader(""), io.Discard, &stderr, failingStore(t), failingReader(t)); code != 0 {
		t.Fatalf("org rm globex: exit = %d, stderr = %q", code, stderr.String())
	}
	if got := stderr.String(); got != "removed org \"globex\"\n" {
		t.Fatalf("org rm with no browser profile stderr = %q, want only the removal line", got)
	}
}
