package driver

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// **The one thing the harness asserts about the agent it cannot see.**
// `Session.agentNeverRan` reads a turn that never started off the ABSENCE of
// `agentLogPath`, and the stub writes that file into `$CLAUDE_CONFIG_DIR` —
// which it learns from the provider record, not from this harness. Two
// computations of one path, in two languages, with a fixture root, an
// `EvalSymlinks` inside `AddProvider` and a `filepath.Join` here between them.
//
// If they ever disagree the harness reports the commonest agent failure —
// *the window never launched the agent* — about a stub that ran perfectly and
// logged somewhere else. #284 spent an afternoon on exactly that class of
// claim, so the agreement is pinned rather than trusted.
func TestTheStubsLogLandsWhereTheHarnessLooksForIt(t *testing.T) {
	stub := stubBinary(t)

	// **/tmp, not t.TempDir().** `/var/folders/...` is reached through a
	// `/var -> private/var` symlink, and this test exists to catch a path
	// disagreement — running it only on the path shape that resolves
	// identically either way would be the test passing on nothing.
	root, err := os.MkdirTemp("/tmp", "wakil-agentlog")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)

	fixture, err := NewFixture(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SeedProfile(fixture); err != nil {
		t.Fatal(err)
	}
	spec := DefaultSeed()
	spec.AgentBinary, spec.AgentScript = stub, filepath.Join(repoRoot(t), AgentStubScript)
	seeded, err := Seed(fixture, spec)
	if err != nil {
		t.Fatal(err)
	}

	// What the WINDOW would pass the stub: the config dir exactly as the
	// provider record carries it, read back through the same loader the app
	// uses rather than recomputed here.
	recorded := recordedConfigDir(t, fixture, seeded)
	// What the HARNESS will look at.
	expected := agentLogPath(fixture, seeded, stub)
	if expected == "" {
		t.Fatal("this run seeded an agent but agentLogPath named no file")
	}

	// Run the stub the way `buildLaunch` runs it — the same four environment
	// keys, and nothing else — and give it a prompt it has no answer for, so
	// it exits rather than waiting on stdin. The log is written before any of
	// that matters: `openLog` runs before the script is even loaded.
	command := exec.Command(stub, "-p")
	command.Env = []string{
		"CLAUDE_CONFIG_DIR=" + recorded,
		"CLAUDE_CODE_OAUTH_TOKEN=" + FixtureProviderToken,
		"HOME=" + fixture.Root,
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
	}
	command.Stdin = strings.NewReader("")
	output, runErr := command.CombinedOutput()

	if _, err := os.Stat(expected); err != nil {
		t.Fatalf("the stub ran with CLAUDE_CONFIG_DIR=%s but the harness looks for its log at "+
			"%s, and nothing is there (%v). A launch like this one would be reported as "+
			"\"the window never launched the scripted agent\" — see #284.\nstub said: %v %s",
			recorded, expected, err, runErr, output)
	}
}

// recordedConfigDir reads the config dir back out of the seeded provider
// record — the value the window resolves and hands the child, and the only one
// that decides where the log goes.
func recordedConfigDir(t *testing.T, fixture Fixture, seeded Seeded) string {
	t.Helper()
	provider := findProviderRecord(t, fixture, seeded)
	body, err := os.ReadFile(provider)
	if err != nil {
		t.Skipf("the provider record is not where this test looks for it (%v); "+
			"the path agreement is still asserted by the check suite", err)
	}
	dir := jsonStringField(string(body), "configDir")
	if dir == "" {
		t.Fatalf("the provider record at %s carries no configDir:\n%s", provider, body)
	}
	return dir
}

// jsonStringField pulls one string field out of a small record without
// modelling the whole of it: this test cares about one key, and a struct here
// would go stale against a record it does not own.
func jsonStringField(body, key string) string {
	at := strings.Index(body, `"`+key+`"`)
	if at < 0 {
		return ""
	}
	rest := body[at+len(key)+2:]
	open := strings.Index(rest, `"`)
	if open < 0 {
		return ""
	}
	rest = rest[open+1:]
	shut := strings.Index(rest, `"`)
	if shut < 0 {
		return ""
	}
	return rest[:shut]
}

// stubBinary finds the scripted agent, and skips rather than fails when a
// fresh clone has not built one — the rule ResolveAgentStub's own message
// states.
//
// **Resolved from the repository root, not the working directory.** `go test`
// runs in the package directory, so `ResolveAgentStub`'s own relative default
// names nothing here — and a skip that fires on every run would make this an
// assertion that cannot fail, which is the one thing e2e.md forbids outright.
func stubBinary(t *testing.T) string {
	t.Helper()
	path, err := ResolveAgentStub(filepath.Join(repoRoot(t), AgentStubBinary))
	if err != nil {
		t.Skipf("no scripted agent built: %v", err)
	}
	return path
}

// repoRoot walks up to the directory holding go.mod.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no go.mod above %s, so the scripted agent cannot be found", dir)
		}
		dir = parent
	}
}

// findProviderRecord locates the seeded provider's JSON under the fixture
// HOME. Searched rather than constructed: the layout is wakilcore's, this
// package does not own it, and a hard-coded path here would go stale silently
// — which is the same class of bug this whole test is about.
func findProviderRecord(t *testing.T, fixture Fixture, seeded Seeded) string {
	t.Helper()
	var found string
	err := filepath.Walk(fixture.Home, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || found != "" {
			return nil //nolint:nilerr // an unreadable branch is not this test's subject
		}
		if filepath.Base(path) == seeded.Provider+".json" {
			found = path
		}
		return nil
	})
	if err != nil || found == "" {
		t.Skipf("no provider record named %s.json under %s (%v)", seeded.Provider, fixture.Home, err)
	}
	return found
}
