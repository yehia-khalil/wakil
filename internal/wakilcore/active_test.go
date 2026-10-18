package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// mkOrgDir creates the org directory that OrgDir() now requires to exist,
// mirroring what Task 3's `wakil org create` will do.
func mkOrgDir(t *testing.T, home, org string) string {
	t.Helper()
	dir := filepath.Join(home, ".wakil", "orgs", org)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir org dir: %v", err)
	}
	return dir
}

func TestActiveRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "default")
	mkOrgDir(t, home, "default")
	if _, err := ReadActive(); err != nil {
		t.Fatalf("ReadActive on empty should be nil error, got %v", err)
	}
	want := ActiveContext{Project: "/x/booking", Environment: "staging"}
	if err := WriteActive(want); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}
	got, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got != want {
		t.Fatalf("round trip mismatch: %+v vs %+v", got, want)
	}
}

func TestWriteActiveNoTmpFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "default")
	orgDir := mkOrgDir(t, home, "default")

	want := ActiveContext{Project: "/x/booking", Environment: "prod"}
	if err := WriteActive(want); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}

	// Check that no .tmp file remains. The active file now lives inside
	// the org's own directory rather than at a flat, org-infixed name.
	tmpFile := filepath.Join(orgDir, "active-default.json.tmp")
	if _, err := os.Stat(tmpFile); !os.IsNotExist(err) {
		t.Fatalf("WriteActive left a .tmp file behind at %s, err=%v", tmpFile, err)
	}

	// Verify the actual file exists.
	activeFile := filepath.Join(orgDir, "active.json")
	info, err := os.Stat(activeFile)
	if err != nil {
		t.Fatalf("active.json does not exist: %v", err)
	}
	// os.CreateTemp creates its file with mode 0600; WriteActive must
	// Chmod it to the 0644 the previous os.WriteFile-based implementation
	// wrote, or every other org member (and any process reading the file
	// without root) loses read access it had before. Dropping the Chmod
	// is a mutation nothing else here catches.
	if got := info.Mode().Perm(); got != 0o644 {
		t.Fatalf("active.json has mode %o, want 0644", got)
	}
	// And that the pre-split shared file was NOT written: nothing may
	// write it again, or two orgs would start sharing state through it.
	if _, err := os.Stat(filepath.Join(home, ".wakil", "active.json")); !os.IsNotExist(err) {
		t.Fatalf("WriteActive wrote the legacy shared active.json, err=%v", err)
	}
}

// TestWriteActiveIsAtomicUnderConcurrentWriters pins the property the
// write-then-rename dance is FOR. A fixed temp path ("<path>.tmp") only
// guards against a crash: two processes in the SAME org — two Claude
// sessions, which is ordinary use — both open that one path with O_TRUNC
// and write from offset 0, so a short write can leave a long write's tail
// behind and the mixed file is renamed into place. Every later ReadActive
// then fails json.Unmarshal, and the operator sees a corrupt active
// context with no way to tell what happened.
//
// MEASURED reliability (see task-2-3-report.md for the full readout): a
// single round of 150 concurrent writer pairs against the pre-fix
// implementation corrupted the file roughly 13-17% of the time — the same
// order of magnitude as this branch's own "1 in 8" precedent for a race
// test that is not reliable enough to trust. Looping several rounds
// inside one test function, failing on the first corrupt round, amplifies
// that substantially: 30/30 independent full-process runs observed here,
// and a separate independent sample of 110 further runs (individual
// batches ranging 80-100%) caught it 104 times — combined, 134/140 ≈ 96%
// detection at 40 rounds, in well under a second of wall time. That is an
// observed rate across a finite sample, not a guarantee: per-round
// failures are close to independent, so a pessimistic 10%-per-round
// estimate predicts ~98.5% detection over 40 rounds (0.9^40 ≈ 1.5% miss),
// and the measured ~96% sits near that estimate rather than clearing it,
// which is consistent with real run-to-run variance under scheduling
// load rather than perfect independence. Still a large, reliable
// improvement over the untreated ~13-17% single-round rate.
func TestWriteActiveIsAtomicUnderConcurrentWriters(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "testorg")
	mkOrgDir(t, home, "testorg")

	// Deliberately very different lengths: a torn write is only observable
	// when one payload is long enough to leave a tail behind the other.
	short := ActiveContext{Project: "/a", Environment: "s"}
	long := ActiveContext{
		Project:     "/" + strings.Repeat("long-project-path-segment/", 40),
		Environment: strings.Repeat("e", 200),
	}

	const rounds = 40
	const iterations = 150
	for round := 0; round < rounds; round++ {
		var wg sync.WaitGroup
		for i := 0; i < iterations; i++ {
			wg.Add(2)
			go func() { defer wg.Done(); _ = WriteActive(short) }()
			go func() { defer wg.Done(); _ = WriteActive(long) }()
		}
		wg.Wait()

		got, err := ReadActive()
		if err != nil {
			t.Fatalf("round %d/%d: after %d concurrent write pairs the active context is unreadable: %v", round, rounds, iterations, err)
		}
		if got.Project != short.Project && got.Project != long.Project {
			t.Fatalf("round %d/%d: active context is a mixture of both writers: %+v", round, rounds, got)
		}
	}
}

// TestWriteActiveDoesNotReuseAFixedTempPath is the deterministic companion
// to the race above: a race test can only ever fail PROBABILISTICALLY, so
// something must pin the actual mechanism. Occupying the old fixed path
// with a directory makes the fixed-path implementation fail outright while
// a per-call temp file is unaffected.
func TestWriteActiveDoesNotReuseAFixedTempPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "testorg")
	mkOrgDir(t, home, "testorg")

	if err := WriteActive(ActiveContext{Project: "/a"}); err != nil {
		t.Fatalf("seed write: %v", err)
	}
	path, err := activePath()
	if err != nil {
		t.Fatalf("activePath: %v", err)
	}
	if err := os.Mkdir(path+".tmp", 0o755); err != nil {
		t.Fatalf("occupying the old fixed temp path: %v", err)
	}

	if err := WriteActive(ActiveContext{Project: "/b"}); err != nil {
		t.Fatalf("WriteActive still depends on the fixed temp path %q: %v", path+".tmp", err)
	}
	got, err := ReadActive()
	if err != nil || got.Project != "/b" {
		t.Fatalf("ReadActive = (%+v, %v), want project /b", got, err)
	}
}

func TestReadActiveMalformedJSON(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "default")
	orgDir := mkOrgDir(t, home, "default")

	// Write malformed JSON with type mismatch: environment should be string, not number
	malformedJSON := []byte(`{"project":"/x/booking","environment": 123}`)
	activeFile := filepath.Join(orgDir, "active.json")
	if err := os.WriteFile(activeFile, malformedJSON, 0o644); err != nil {
		t.Fatalf("Failed to write malformed JSON: %v", err)
	}

	// ReadActive should return an error and zero ActiveContext
	got, err := ReadActive()

	// Assert error is non-nil
	if err == nil {
		t.Fatalf("ReadActive on malformed JSON should return non-nil error, got nil")
	}

	// Assert returned context is zero value, not partially populated
	zero := ActiveContext{}
	if got != zero {
		t.Fatalf("ReadActive should return zero ActiveContext on unmarshal error, got %+v", got)
	}
}

// TestActiveContextIsPerOrg is the point of splitting the file: two orgs
// running side by side must not overwrite each other's active project.
//
// Before the split there was one ~/.wakil/active.json shared by every org,
// so setting a project in one account left the others pointing at a
// project they were not allowed to open. Resolve() refused it correctly —
// this was never a safety hole — but it meant re-running set_project on
// every account switch, and the cost grows with each account added. The
// operator is adding a third.
func TestActiveContextIsPerOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	mkOrgDir(t, home, "alpha")
	mkOrgDir(t, home, "beta")

	t.Setenv("WAKIL_ORG", "alpha")
	alpha := ActiveContext{Project: "/x/alpha", Environment: "staging"}
	if err := WriteActive(alpha); err != nil {
		t.Fatalf("WriteActive(alpha): %v", err)
	}

	t.Setenv("WAKIL_ORG", "beta")
	// Assert the guard FIRED: beta must see nothing, not alpha's project.
	got, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive(beta): %v", err)
	}
	if got != (ActiveContext{}) {
		t.Fatalf("beta saw alpha's active context %+v — the file is still shared", got)
	}
	beta := ActiveContext{Project: "/x/beta", Environment: "prod"}
	if err := WriteActive(beta); err != nil {
		t.Fatalf("WriteActive(beta): %v", err)
	}

	// Alpha must be untouched by beta's write.
	t.Setenv("WAKIL_ORG", "alpha")
	got, err = ReadActive()
	if err != nil {
		t.Fatalf("ReadActive(alpha): %v", err)
	}
	if got != alpha {
		t.Fatalf("alpha's context = %+v, want %+v — beta's write clobbered it", got, alpha)
	}
}

// TestActivePathRejectsAnOrgThatIsNotFilenameSafe pins the guard on
// putting an org id into a path: activePath() must refuse an org that
// cannot be used as a filename component, not silently sanitise it.
// Sanitising two different WAKIL_ORG values onto one token would share an
// active context, which is the exact bug the per-org split removes.
func TestActivePathRejectsAnOrgThatIsNotFilenameSafe(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	for _, tc := range []struct{ name, org string }{
		{"root", "/"},
		{"dotdot", ".."},
		{"single dot", "."},
		{"bare dash", "-"},
		{"bare space", " "},
	} {
		org := tc.org
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("WAKIL_ORG", org)
			path, err := activePath()
			if err == nil {
				t.Fatalf("activePath() = %q for org %q, want a refusal", path, org)
			}
			msg, ok := IsUserError(err)
			if !ok || !strings.Contains(msg, "unusable org id") {
				t.Fatalf("error = %v, want a UserError naming the unusable org id", err)
			}
			// The refusal must also stop a WRITE, not merely the path
			// computation — otherwise the guard is decorative.
			if err := WriteActive(ActiveContext{Project: "/x/y"}); err == nil {
				t.Fatal("WriteActive succeeded with an unusable org id")
			}
		})
	}
}

// TestActiveContextLivesInsideTheOrgDirectory pins the new location: the
// active context is a file inside ~/.wakil/orgs/<org>/, not a flat,
// org-infixed file directly under ~/.wakil.
func TestActiveContextLivesInsideTheOrgDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: "/p/.wakil/project.json", Environment: "staging"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "orgs", "initech", "active.json")); err != nil {
		t.Fatalf("active context not written inside the org directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "active-initech.json")); !os.IsNotExist(err) {
		t.Errorf("the old flat path must not be written any more")
	}
}

// TestNoLegacyActiveFallback pins the deletion of readLegacyActive. Before
// this change, ReadActive fell back to a pre-split shared ~/.wakil/active.json
// whenever the current org had no file of its own, adopting it if the
// project it named belonged to the current org. That fallback, and the
// on-disk layout it bridged to, no longer exist (design §9): a project
// naming this org in the legacy shared file must NOT be adopted.
func TestNoLegacyActiveFallback(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	orgDir := filepath.Join(home, ".wakil", "orgs", "initech")
	if err := os.MkdirAll(orgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A pre-split shared file naming a project that DOES belong to this org.
	// Before this change readLegacyActive would have adopted it.
	projDir := t.TempDir()
	projPath := filepath.Join(projDir, "project.json")
	if err := os.WriteFile(projPath, []byte(`{"name":"p","org":"initech"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(home, ".wakil", "active.json")
	if err := os.WriteFile(legacy, []byte(`{"project":"`+projPath+`","environment":"staging"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	a, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if a.Project != "" {
		t.Errorf("ReadActive adopted the legacy shared file (%q); the fallback must be gone", a.Project)
	}
}

// TestActiveProviderRoundTrips pins the fourth axis: a provider written
// through WriteActive comes back through ReadActive, exactly like Project
// and Environment already do. There is no parallel SetActiveProvider /
// ActiveProvider accessor pair — ReadActive/WriteActive is the one and
// only read/write path for every field on ActiveContext, and this field
// is no exception.
func TestActiveProviderRoundTrips(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}

	want := ActiveContext{Project: "/x/booking", Environment: "staging", Provider: "main"}
	if err := WriteActive(want); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}
	got, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got != want {
		t.Fatalf("round trip mismatch: %+v vs %+v", got, want)
	}
}

// TestActiveProviderIsEmptyBeforeItIsSet pins that absence is an ordinary
// state, not an error: an active.json written before this field existed —
// or one that has simply never had a provider chosen — must still read
// back cleanly, with Provider reporting "" rather than ReadActive failing.
func TestActiveProviderIsEmptyBeforeItIsSet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}

	got, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got.Provider != "" {
		t.Fatalf("Provider = %q before it was ever set, want empty", got.Provider)
	}

	// Also cover the case the brief calls out explicitly: a project and
	// environment set through the existing fields, with no provider ever
	// written, must not make Provider anything other than "".
	if err := WriteActive(ActiveContext{Project: "/x/booking", Environment: "staging"}); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}
	got, err = ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got.Provider != "" {
		t.Fatalf("Provider = %q after writing an active context with none set, want empty", got.Provider)
	}
}

// pinFixture registers projects "a" and "b" in org "initech" (each with a
// project.json declaring orgOf[name], default "initech") and writes an
// active.json naming a's path, environment staging, provider p1. It
// returns the two project.json paths.
func pinFixture(t *testing.T, orgOf map[string]string) (aPath, bPath string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	mkOrgDir(t, home, "initech")
	paths := map[string]string{}
	reg := map[string]ProjectEntry{}
	for _, name := range []string{"a", "b"} {
		org := orgOf[name]
		if org == "" {
			org = "initech"
		}
		dir := filepath.Join(home, name, ".wakil")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, "project.json")
		body := `{"name":"` + name + `","org":"` + org + `","roots":[{"path":"."}],"environments":{"staging":{"databases":[]},"local":{"databases":[]}}}`
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		paths[name] = p
		reg[name] = ProjectEntry{Path: p}
	}
	if err := SaveRegistry("initech", reg); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: paths["a"], Environment: "staging", Provider: "p1"}); err != nil {
		t.Fatal(err)
	}
	return paths["a"], paths["b"]
}

func TestReadActivePinnedProjectOverridesFile(t *testing.T) {
	_, bPath := pinFixture(t, nil)
	t.Setenv("WAKIL_PROJECT", "b")
	t.Setenv("WAKIL_ENVIRONMENT", "local")
	got, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	want := ActiveContext{Project: bPath, Environment: "local", Provider: "p1"}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestReadActivePinnedEnvironmentOnly(t *testing.T) {
	aPath, _ := pinFixture(t, nil)
	t.Setenv("WAKIL_ENVIRONMENT", "local")
	got, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if got.Project != aPath || got.Environment != "local" {
		t.Fatalf("got %+v", got)
	}
}

func TestReadActiveEmptyPinIsUnset(t *testing.T) {
	aPath, _ := pinFixture(t, nil)
	t.Setenv("WAKIL_PROJECT", "")
	t.Setenv("WAKIL_ENVIRONMENT", "")
	got, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if got.Project != aPath || got.Environment != "staging" {
		t.Fatalf("got %+v", got)
	}
}

func TestReadActivePinnedUnknownProjectFails(t *testing.T) {
	pinFixture(t, nil)
	t.Setenv("WAKIL_PROJECT", "nope")
	_, err := ReadActive()
	if err == nil || !strings.Contains(err.Error(), "nope") || !strings.Contains(err.Error(), "not registered") {
		t.Fatalf("got %v", err)
	}
}

func TestResolvePinnedProjectOtherOrgRefused(t *testing.T) {
	pinFixture(t, map[string]string{"b": "other"})
	t.Setenv("WAKIL_PROJECT", "b")
	_, err := Resolve()
	if err == nil || !strings.Contains(err.Error(), "belongs to org") {
		t.Fatalf("got %v", err)
	}
}

func TestSetProjectCheckedRefusedWhenPinned(t *testing.T) {
	pinFixture(t, nil)
	path, _ := activePath()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROJECT", "b")
	err = SetProjectChecked("a")
	if err == nil || !strings.Contains(err.Error(), "pinned") {
		t.Fatalf("got %v", err)
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("want a UserError, got %T", err)
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("active.json changed")
	}
}

func TestReadActiveUnpinnedIgnoresThePins(t *testing.T) {
	aPath, _ := pinFixture(t, nil)
	t.Setenv("WAKIL_PROJECT", "b")
	t.Setenv("WAKIL_ENVIRONMENT", "local")
	got, err := ReadActiveUnpinned()
	if err != nil {
		t.Fatal(err)
	}
	if got.Project != aPath || got.Environment != "staging" {
		t.Fatalf("got %+v", got)
	}
}

func TestSetProjectCheckedWithOnlyEnvironmentPinnedKeepsTheFilesEnvironment(t *testing.T) {
	pinFixture(t, nil)
	t.Setenv("WAKIL_ENVIRONMENT", "local")
	if err := SetProjectChecked("b"); err != nil {
		t.Fatal(err)
	}
	got, err := ReadActiveUnpinned()
	if err != nil {
		t.Fatal(err)
	}
	if got.Environment != "staging" {
		t.Fatalf("pinned environment leaked into active.json: %+v", got)
	}
}

// A pinned project takes its environment from WAKIL_ENVIRONMENT alone. The
// file's environment belongs to whatever project the operator has on screen
// now, so laying it under a pinned project would hand the pinned session
// an environment it never started in — production, at worst.
func TestReadActivePinnedProjectNeverTakesTheFilesEnvironment(t *testing.T) {
	aPath, _ := pinFixture(t, nil)
	if err := WriteActive(ActiveContext{Project: aPath, Environment: "production", Provider: "p1"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROJECT", "b")
	t.Setenv("WAKIL_ENVIRONMENT", "")
	got, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if got.Environment != "" {
		t.Fatalf("Environment = %q, want \"\" (pinned project, WAKIL_ENVIRONMENT unset)", got.Environment)
	}
}

// Resolve reports the registry key of a pinned project as the pin itself,
// and of an unpinned one by looking the active path up in the registry.
func TestResolveReportsTheProjectKey(t *testing.T) {
	pinFixture(t, nil)
	r, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.ProjectKey != "a" {
		t.Fatalf("unpinned ProjectKey = %q, want a", r.ProjectKey)
	}
	t.Setenv("WAKIL_PROJECT", "b")
	r, err = Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.ProjectKey != "b" {
		t.Fatalf("pinned ProjectKey = %q, want b", r.ProjectKey)
	}
}
