package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeProject(t *testing.T, dir, name, org string) string {
	t.Helper()
	pj := filepath.Join(dir, ".wakil")
	if err := os.MkdirAll(pj, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(pj, "project.json")
	if err := os.WriteFile(path, []byte(`{"name":"`+name+`","org":"`+org+`","roots":[{"path":"."}],"environments":{"staging":{"databases":[]}}}`), 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}
	return path
}

func TestSetProjectRejectsCrossOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	proj247 := writeProject(t, filepath.Join(home, "p247"), "p247", "initech")
	projGath := writeProject(t, filepath.Join(home, "pgath"), "pgath", "umbrella")

	if err := SaveRegistry("initech", map[string]ProjectEntry{"p247": {Path: proj247}, "pgath": {Path: projGath}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}

	if err := SetProjectChecked("p247"); err != nil {
		t.Fatalf("same-org set should succeed: %v", err)
	}
	err := SetProjectChecked("pgath")
	if err == nil {
		t.Fatal("cross-org set must be rejected")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected user error, got %v", err)
	}
}

// TestResolveRejectsCrossOrgOnSwitch verifies that Resolve() re-checks the org
// every time it is called, not just at set-time. A project set under one
// WAKIL_ORG must be rejected by Resolve() once WAKIL_ORG (and therefore
// CurrentOrg()) changes to point at a different org.
func TestResolveRejectsCrossOrgOnSwitch(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	proj247 := writeProject(t, filepath.Join(home, "p247"), "p247", "initech")

	if err := SaveRegistry("initech", map[string]ProjectEntry{"p247": {Path: proj247}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}

	if err := SetProjectChecked("p247"); err != nil {
		t.Fatalf("same-org set should succeed: %v", err)
	}

	// Resolve should succeed while still in the same org.
	if _, err := Resolve(); err != nil {
		t.Fatalf("Resolve() in same org should succeed: %v", err)
	}

	// Switch to a different org whose active context happens to name
	// p247. Active context is per-org (activePath resolves through
	// OrgDir()), so merely switching WAKIL_ORG does not make umbrella see
	// p247 by itself — umbrella's own active.json is empty, and reading it
	// hits the "no active project" guard rather than the proj.Org !=
	// currentOrg check this test exists to pin. Seeding umbrella's file
	// directly with p247's path is what actually reaches that check; the
	// umbrella org directory must also exist, or OrgDir() would refuse the
	// org before WriteActive gets anywhere near it.
	t.Setenv("WAKIL_ORG", "umbrella")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "umbrella"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	if err := WriteActive(ActiveContext{Project: proj247}); err != nil {
		t.Fatalf("seed umbrella's active context with p247: %v", err)
	}

	_, err := Resolve()
	if err == nil {
		t.Fatal("Resolve() must reject a project whose org no longer matches CurrentOrg()")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected user error, got %v", err)
	}
	// Pin the actual branch, not merely "some UserError": without this,
	// the "no active project" guard would satisfy the assertions above
	// just as well and the cross-org check would go uncovered again.
	if !strings.Contains(err.Error(), "belongs to org") {
		t.Fatalf("expected the cross-org rejection, got %v", err)
	}
}

// TestSetProjectClearsStaleEnvironment verifies that switching to a project
// which does not define the currently active environment clears it, and that
// switching to a project which does define it preserves it.
func TestSetProjectClearsStaleEnvironment(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	projA := writeProject(t, filepath.Join(home, "projA"), "projA", "initech")
	projB := writeProject(t, filepath.Join(home, "projB"), "projB", "initech")

	if err := SaveRegistry("initech", map[string]ProjectEntry{"projA": {Path: projA}, "projB": {Path: projB}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}

	if err := SetProjectChecked("projA"); err != nil {
		t.Fatalf("SetProjectChecked(projA): %v", err)
	}
	active, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	active.Environment = "staging"
	if err := WriteActive(active); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}

	// Switch to projB, which also defines "staging" -> should be preserved.
	if err := SetProjectChecked("projB"); err != nil {
		t.Fatalf("SetProjectChecked(projB): %v", err)
	}
	active, err = ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if active.Environment != "staging" {
		t.Fatalf("expected environment to be preserved as 'staging', got %q", active.Environment)
	}

	// Now write a project that does NOT define "staging".
	projC := filepath.Join(home, "projC", ".wakil", "project.json")
	if err := os.MkdirAll(filepath.Dir(projC), 0o755); err != nil {
		t.Fatalf("mkdir projC: %v", err)
	}
	if err := os.WriteFile(projC, []byte(`{"name":"projC","org":"initech","roots":[{"path":"."}],"environments":{"production":{"databases":[]}}}`), 0o644); err != nil {
		t.Fatalf("write projC project.json: %v", err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"projA": {Path: projA}, "projB": {Path: projB}, "projC": {Path: projC}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}

	if err := SetProjectChecked("projC"); err != nil {
		t.Fatalf("SetProjectChecked(projC): %v", err)
	}
	active, err = ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if active.Environment != "" {
		t.Fatalf("expected stale environment to be cleared, got %q", active.Environment)
	}
}

// TestResolveEnvironmentRejectsUnknownEnvironment verifies that
// ResolveEnvironment() returns a UserError when the active environment name
// is not one of the project's defined environments.
func TestResolveEnvironmentRejectsUnknownEnvironment(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	proj := writeProject(t, filepath.Join(home, "proj"), "proj", "initech")

	if err := SaveRegistry("initech", map[string]ProjectEntry{"proj": {Path: proj}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}

	if err := SetProjectChecked("proj"); err != nil {
		t.Fatalf("SetProjectChecked: %v", err)
	}

	active, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	active.Environment = "production" // not defined by this project (only "staging" is)
	if err := WriteActive(active); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}

	_, err = ResolveEnvironment()
	if err == nil {
		t.Fatal("ResolveEnvironment() must reject an environment name not defined by the project")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected user error, got %v", err)
	}
}

// TestResolveEchoesTheActiveProvider verifies that Resolve() reports the
// active context's Provider field (Task 7's fourth axis) as
// Resolved.ActiveProvider — distinct from Resolved.Provider, which is the
// advisory Selected-vs-Running comparison (this project's declared
// default versus whatever WAKIL_PROVIDER the current process launched
// under) and already existed before this field. get_context hands
// Resolved straight back as structuredContent, so this is also the check
// that the provider the operator picked reaches the wire.
func TestResolveEchoesTheActiveProvider(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}

	proj := writeProject(t, filepath.Join(home, "proj"), "proj", "initech")
	if err := SaveRegistry("initech", map[string]ProjectEntry{"proj": {Path: proj}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}
	if err := SetProjectChecked("proj"); err != nil {
		t.Fatalf("SetProjectChecked: %v", err)
	}

	active, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	active.Provider = "main"
	if err := WriteActive(active); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}

	r, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if r.ActiveProvider != "main" {
		t.Fatalf("ActiveProvider = %q, want %q", r.ActiveProvider, "main")
	}
}

// TestResolveReportsProviderMismatchWithoutBlocking verifies that a
// project whose registry entry names a different provider than the one
// actually running produces a mismatch report, and that Resolve() still
// succeeds — per §7, the preference is reported, never enforced.
func TestResolveReportsProviderMismatchWithoutBlocking(t *testing.T) {
	projPath := twoProviderFixture(t)
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: projPath, Provider: "backup"}}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROVIDER", "primary")

	r, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve() must not fail on a provider mismatch: %v", err)
	}
	if r.Provider.Selected != "backup" || r.Provider.Running != "primary" || r.Provider.Match {
		t.Errorf("Provider = %+v; want selected=backup running=primary match=false", r.Provider)
	}
}

// TestResolveFallsBackToTheOrgDefaultProvider verifies that when the
// project's registry entry names no provider, the org's DefaultProvider
// is adopted as Selected instead.
func TestResolveFallsBackToTheOrgDefaultProvider(t *testing.T) {
	projPath := twoProviderFixture(t)
	if err := SaveOrg("initech", Org{DefaultProvider: "primary"}); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: projPath}}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROVIDER", "primary")

	r, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.Provider.Selected != "primary" || !r.Provider.Match {
		t.Errorf("Provider = %+v; want the org default adopted and matched", r.Provider)
	}
}

// TestResolveSaysWhenTheLauncherDeclaredNoProvider verifies that an
// unset WAKIL_PROVIDER produces an explicit note rather than treating an
// empty running provider as a match or a mismatch.
func TestResolveSaysWhenTheLauncherDeclaredNoProvider(t *testing.T) {
	twoProviderFixture(t)
	t.Setenv("WAKIL_PROVIDER", "")

	r, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.Provider.Running != "" || r.Provider.Note == "" {
		t.Errorf("Provider = %+v; want an explicit note rather than a guess", r.Provider)
	}
	const want = "the launcher did not declare WAKIL_PROVIDER, so the running provider is unknown"
	if r.Provider.Note != want {
		t.Errorf("Note = %q, want %q", r.Provider.Note, want)
	}
}

// TestResolveSaysWhenWAKIL_PROVIDERIsUnregistered pins finding 4 of the
// final review. Before this fix, providerReport discarded
// CurrentProvider's error and fell straight into the "did not declare"
// branch above, so WAKIL_PROVIDER=typo produced the same false note as
// WAKIL_PROVIDER being unset entirely — even though the launcher very
// much DID declare one, and spec §3.2 calls an unknown id an error.
// TestCurrentProviderRejectsUnregisteredID (provider_test.go) pins that
// CurrentProvider itself returns an error for this input; this test pins
// that providerReport's ONLY production caller actually surfaces it
// instead of swallowing it into a misleading note — and that doing so
// still never fails Resolve, since a provider mismatch is advisory only.
func TestResolveSaysWhenWAKIL_PROVIDERIsUnregistered(t *testing.T) {
	twoProviderFixture(t)
	t.Setenv("WAKIL_PROVIDER", "typo")

	r, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve() must not fail on an unregistered WAKIL_PROVIDER: %v", err)
	}
	if r.Provider.Running != "" {
		t.Errorf("Running = %q, want empty — CurrentProvider never named an unregistered id as running", r.Provider.Running)
	}
	if !strings.Contains(r.Provider.Note, "typo") {
		t.Errorf("Note = %q, want it to name the unregistered id %q", r.Provider.Note, "typo")
	}
	if !strings.Contains(r.Provider.Note, "not registered") {
		t.Errorf("Note = %q, want it to say the id is not registered, not that none was declared", r.Provider.Note)
	}
	if strings.Contains(r.Provider.Note, "did not declare") {
		t.Errorf("Note = %q; WAKIL_PROVIDER=typo DID declare one — this note is false for this input", r.Provider.Note)
	}
}

// TestProviderReportMatchesRegistryEntryByPathNotName pins decision 1 from
// the org/provider decoupling design: providerReport must join the active
// project to a registry entry by PATH, not by matching the project's own
// name against the registry key. The registry key and project.json's
// "name" field are written independently and can disagree; twoProviderFixture
// happens to use the same string ("booking") for both, so a test built only
// on that fixture's default registry cannot tell path-matching from
// name-matching apart. This test deliberately sets the two apart: the
// entry actually at projPath is filed under an unrelated key ("relocated"),
// and the "booking" key instead points at a path that must never be
// consulted. If providerReport ever changed to look up the registry by the
// project's declared name instead of its path, it would read the "booking"
// entry (provider "primary") instead of the "relocated" one (provider
// "backup"), and this test would fail.
func TestProviderReportMatchesRegistryEntryByPathNotName(t *testing.T) {
	projPath := twoProviderFixture(t)
	if err := SaveRegistry("initech", map[string]ProjectEntry{
		"relocated": {Path: projPath, Provider: "backup"},
		"booking":   {Path: "/nonexistent-path-must-never-be-read", Provider: "primary"},
	}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROVIDER", "backup")

	r, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.Provider.Selected != "backup" || !r.Provider.Match {
		t.Errorf("Provider = %+v; want the entry found by path (relocated -> backup), not by a registry key that happens to equal the project's name", r.Provider)
	}
}
