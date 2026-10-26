package driver

import (
	"database/sql"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/internal/wakilcore"

	_ "modernc.org/sqlite"
)

// seedInto lays out a fixture under t.TempDir() and seeds it, failing the
// test on either step. Every test below asserts on state read back through
// `wakilcore`'s OWN loaders rather than through the writer under test: a
// field production stopped reading would still satisfy an assertion made
// against marshalled bytes, and the point of the seed is that production
// can load it.
func seedInto(t *testing.T, spec SeedSpec) (Fixture, Seeded) {
	t.Helper()
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	seeded, err := Seed(fixture, spec)
	if err != nil {
		t.Fatalf("Seed: %v", err)
	}
	return fixture, seeded
}

// The org has to exist as a DIRECTORY before anything else will look at it:
// OrgDirFor refuses an unregistered org outright, which is what turns a
// mistyped org into an error instead of state under a phantom one.
func TestSeedRegistersAnOrgProductionCanLoad(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)

	org, err := wakilcore.LoadOrgFor(seeded.Org)
	if err != nil {
		t.Fatalf("LoadOrgFor(%q): %v", seeded.Org, err)
	}
	if org.DisplayName == "" {
		t.Errorf("the seeded org has no displayName; got %+v", org)
	}
}

// The provider's config dir must live INSIDE the fixture. This is the "Claude
// config dirs" half of the fixture contract (#248), and it is seeded rather
// than injected as an environment variable because `CurrentOrg`'s own doc
// comment records that wakilcore deliberately has NO fallback to
// CLAUDE_CONFIG_DIR (paths.go) — the config dir travels on the provider
// record and nowhere else. A record pointing at ~/.claude-initech would run a
// check against the operator's real account.
func TestSeedProviderConfigDirIsInsideTheFixture(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)

	provider, err := wakilcore.LoadProviderFor(seeded.Org, seeded.Provider)
	if err != nil {
		t.Fatalf("LoadProviderFor: %v", err)
	}
	if provider.Kind != wakilcore.ProviderKindClaudeCode {
		t.Errorf("kind = %q, want %q", provider.Kind, wakilcore.ProviderKindClaudeCode)
	}
	if provider.ConfigDir == "" {
		t.Fatal("the seeded provider carries no configDir")
	}
	// Resolved, because AddProvider stores the EvalSymlinks-resolved path and
	// a fixture under /var symlinks to /private/var on macOS.
	root, err := filepath.EvalSymlinks(fixture.Root)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(provider.ConfigDir, root) {
		t.Errorf("configDir = %q, which is outside the fixture root %q", provider.ConfigDir, root)
	}
	if _, err := os.Stat(provider.ConfigDir); err != nil {
		t.Errorf("configDir does not exist: %v", err)
	}
}

// The org's defaultProvider names the seeded provider. CreateOrg refuses to
// set this before the provider is registered, so it is evidence the seed got
// the ordering right rather than a restatement of the field.
func TestSeedOrgDefaultProviderNamesTheSeededProvider(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)

	org, err := wakilcore.LoadOrgFor(seeded.Org)
	if err != nil {
		t.Fatal(err)
	}
	if org.DefaultProvider != seeded.Provider {
		t.Errorf("defaultProvider = %q, want %q", org.DefaultProvider, seeded.Provider)
	}
}

// **The assertion that matters.** `Resolve()` is what `get_context` calls, and
// `get_context` is what the app's `refreshContext` reads to set
// `WindowModel.organization` — which `WakilWindow`'s `hasOpenOrg` gates the
// org plane on. So a seed that satisfies `Resolve()` is a seed the app opens
// onto an org, and one that does not is the "NO ORGANISATION IS OPEN" plane
// with no way past it.
//
// It also covers the trap that `active.json` holds the project's PATH and not
// its name (SetProjectChecked, resolve.go): a seed that wrote the name would
// still produce a readable active.json and would fail here.
func TestSeedResolvesTheWayGetContextWill(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)

	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if resolved.Org != seeded.Org {
		t.Errorf("Org = %q, want %q", resolved.Org, seeded.Org)
	}
	if resolved.Project == nil {
		t.Fatal("Resolve reported no project")
	}
	if resolved.Project.Name != seeded.Project {
		t.Errorf("Project.Name = %q, want %q", resolved.Project.Name, seeded.Project)
	}
	if resolved.Environment != seeded.Environment {
		t.Errorf("Environment = %q, want %q", resolved.Environment, seeded.Environment)
	}
	if resolved.ActiveProvider != seeded.Provider {
		t.Errorf("ActiveProvider = %q, want %q", resolved.ActiveProvider, seeded.Provider)
	}
	if len(resolved.RootPaths) == 0 {
		t.Error("no root paths: WindowSession launches into RootPaths.first, and an empty set leaves it at NSHomeDirectory()")
	}
}

// The seeded environment must not be read as production. A fixture that
// resolved as production would price every seeded mutation through the
// write gate and refuse it (Decision 26, #182), so every check that acts
// would fail for a reason having nothing to do with what it tested.
func TestSeedEnvironmentIsNotProduction(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)

	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatal(err)
	}
	env := resolved.Project.Environments[seeded.Environment]
	if wakilcore.EnvironmentIsProduction(seeded.Environment, env) {
		t.Errorf("the seeded environment %q reads as production", seeded.Environment)
	}
}

// **The guard that keeps the seed off the operator's own store.** `Seed`
// overrides HOME so wakilcore's writers resolve ~/.wakil inside the fixture;
// the same call with a home it does not own writes a real org into the real
// store. This is the global "never touch the real ~/.wakil" constraint, so it
// is a refusal and not a warning.
func TestSeedRefusesAHomeOutsideTheFixtureRoot(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()

	// **The refusal must come from the guard, by name.** Asserting only that
	// an error came back is not enough, and that is measured rather than
	// assumed: with `guardFixtureHome` neutered to `return nil`, two of these
	// four cases still failed — later, for unrelated reasons — and the test
	// stayed green. A guard that had been deleted would have been reported as
	// present. So each case asserts that the error is the refusal.
	for name, fixture := range map[string]Fixture{
		"home outside the root": {Root: root, Home: outside},
		"home IS the root":      {Root: root, Home: root},
		"empty home":            {Root: root, Home: ""},
		"empty root":            {Root: "", Home: outside},
	} {
		_, err := Seed(fixture, DefaultSeed())
		if err == nil {
			t.Errorf("%s: Seed returned no error, so it would have written outside the fixture", name)
			continue
		}
		if !strings.Contains(err.Error(), "refusing to write") {
			t.Errorf("%s: Seed failed for the wrong reason, so the guard is not what stopped it: %v", name, err)
		}
	}
}

// HOME and WAKIL_ORG are the seeding window's, not the run's. A Seed that
// leaked HOME would leave every later wakilcore call in this process — and
// every test after it — resolving ~/.wakil inside a fixture that teardown
// then deletes.
func TestSeedRestoresTheEnvironmentItOverrode(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "sentinel-org")
	homeBefore := os.Getenv("HOME")

	if _, err := seedOnly(t, DefaultSeed()); err != nil {
		t.Fatal(err)
	}

	if got := os.Getenv("HOME"); got != homeBefore {
		t.Errorf("HOME = %q after Seed, want the pre-seed %q", got, homeBefore)
	}
	if got := os.Getenv("WAKIL_ORG"); got != "sentinel-org" {
		t.Errorf("WAKIL_ORG = %q after Seed, want the pre-seed \"sentinel-org\"", got)
	}
}

// A variable that was UNSET before the seed must be unset after it, not set to
// the empty string: `CurrentOrg` treats "" as "not set" and reports it, but
// `os.LookupEnv` elsewhere would see a value where there was none.
func TestSeedUnsetsWhatWasUnset(t *testing.T) {
	t.Setenv("WAKIL_ORG", "")
	if err := os.Unsetenv("WAKIL_ORG"); err != nil {
		t.Fatal(err)
	}

	if _, err := seedOnly(t, DefaultSeed()); err != nil {
		t.Fatal(err)
	}

	if _, present := os.LookupEnv("WAKIL_ORG"); present {
		t.Error("WAKIL_ORG is present after Seed, but it was unset before")
	}
}

// seedOnly seeds a fresh fixture and returns Seed's own error, for the tests
// that are about Seed's effect on the process rather than on the disk.
func seedOnly(t *testing.T, spec SeedSpec) (Seeded, error) {
	t.Helper()
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return Seed(fixture, spec)
}

// **WAKIL_ORG is what makes the seeded state visible, and nothing else
// supplies it.** `CurrentOrg` reads that variable and has deliberately no
// fallback (paths.go), and `WakilWiring.build` passes the app's own
// WAKIL_ORG down to every spawned Go child (AppWiring.swift). So a launch
// that carried the seed on disk but not this variable would resolve no org
// at all and sit on the "NO ORGANISATION IS OPEN" plane with the state it
// needed already present.
func TestFixtureEnvCarriesTheSeededOrg(t *testing.T) {
	fixture := Fixture{Root: "/f", Home: "/f/home", TmpDir: "/f/tmp", BinDir: "/f/bin"}
	seeded := Seeded{Org: "e2e-fixture", Provider: "e2e-provider"}

	env := map[string]string{}
	for _, assignment := range fixture.Env("/usr/bin:/bin", seeded) {
		name, value, _ := strings.Cut(assignment, "=")
		env[name] = value
	}

	if env["WAKIL_ORG"] != "e2e-fixture" {
		t.Errorf("WAKIL_ORG = %q, want the seeded org", env["WAKIL_ORG"])
	}
	// The four already-proven axes must survive the addition.
	if env["HOME"] != "/f/home" || env["TMPDIR"] != "/f/tmp" {
		t.Errorf("HOME/TMPDIR regressed: %q / %q", env["HOME"], env["TMPDIR"])
	}
	if !strings.HasPrefix(env["PATH"], "/f/bin:") {
		t.Errorf("PATH = %q, want the fixture bin first", env["PATH"])
	}
}

// An UNSEEDED launch must not claim an org. This is the org-plane case the
// spine's own check (e2e/checks/unseeded/org-plane.jsonl) asserts, and it stays
// reachable: `WAKIL_ORG=` empty would be reported by `CurrentOrg` as "not
// set", but an assignment present with an empty value is a different fact on
// the wire, and `childProcessEnvironment` forwards an org "only when
// non-nil: absent means unset, never the empty string".
func TestFixtureEnvOmitsWakilOrgWhenNothingWasSeeded(t *testing.T) {
	fixture := Fixture{Root: "/f", Home: "/f/home", TmpDir: "/f/tmp", BinDir: "/f/bin"}

	for _, assignment := range fixture.Env("/usr/bin:/bin", Seeded{}) {
		if strings.HasPrefix(assignment, "WAKIL_ORG=") {
			t.Errorf("an unseeded fixture still carried %q", assignment)
		}
	}
}

// A RELATIVE fixture root must be refused, not resolved against the working
// directory.
//
// **This is not hypothetical.** While proving the guard above could fail, a run
// with `Root: ""` and the guard neutered wrote `e2e/driver/project/.wakil/
// project.json` into the repository itself — `filepath.Join("", "project")` is
// the relative path `"project"`, and the production writers resolved it against
// the test's working directory. `filepath.Abs` inside the guard makes a relative
// root and a relative home agree with each other, so containment alone says
// nothing; the root has to be absolute for "inside the fixture" to mean
// anything at all.
func TestSeedRefusesARelativeFixtureRoot(t *testing.T) {
	_, err := Seed(Fixture{Root: "relative-root", Home: filepath.Join("relative-root", "home")}, DefaultSeed())
	if err == nil {
		t.Fatal("Seed accepted a relative fixture root, so it would write beside the working directory")
	}
	if !strings.Contains(err.Error(), "refusing to write") {
		t.Errorf("Seed failed for the wrong reason, so the guard is not what stopped it: %v", err)
	}
}

// A fixture home that is a SYMLINK out of the root must be refused.
//
// **The guard's claim is that writing outside the fixture "cannot happen
// quietly", and a lexical check does not earn it.** `filepath.Abs` is
// string-level and `os.Stat` follows links, so `<root>/home` pointing at the
// operator's real home satisfied containment, existence and directory-ness —
// and wakilcore would then write a real org into the real `~/.wakil`. That is
// the global "never touch the real ~/.wakil" constraint, so it is the one case
// the guard most has to catch.
func TestSeedRefusesAHomeThatSymlinksOutOfTheRoot(t *testing.T) {
	root := t.TempDir()
	elsewhere := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.Symlink(elsewhere, home); err != nil {
		t.Fatal(err)
	}

	_, err := Seed(Fixture{Root: root, Home: home}, DefaultSeed())
	if err == nil {
		t.Fatal("Seed accepted a home symlinked out of the fixture root")
	}
	if !strings.Contains(err.Error(), "refusing to write") {
		t.Errorf("Seed failed for the wrong reason, so the guard is not what stopped it: %v", err)
	}
}

// Seeding the SAME fixture twice must work, because `--fixture <dir>` exists so
// an operator can reuse a directory across runs.
//
// **`wakilcore.CreateOrg` refuses an org that already exists** (org.go), so a
// second run against one explicit `--fixture` died with `org "e2e-fixture"
// already exists` — a confusing failure for the one flag whose purpose is
// reuse. #248 asks for the seed to build its state "reproducibly, from
// nothing", and that has to hold on the second run as well as the first.
func TestSeedIsRepeatableAgainstTheSameFixture(t *testing.T) {
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	first, err := Seed(fixture, DefaultSeed())
	if err != nil {
		t.Fatalf("first Seed: %v", err)
	}
	second, err := Seed(fixture, DefaultSeed())
	if err != nil {
		t.Fatalf("second Seed against the same fixture: %v", err)
	}
	if first.Org != second.Org {
		t.Errorf("the two seeds disagree: %q then %q", first.Org, second.Org)
	}

	// And the state is still the one thing production resolves, not a doubled
	// or half-overwritten version of it.
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", second.Org)
	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatalf("Resolve after re-seeding: %v", err)
	}
	if resolved.Environment != second.Environment {
		t.Errorf("Environment = %q, want %q", resolved.Environment, second.Environment)
	}
}

// **A second organisation, because a switch needs somewhere to switch to.**
// 2c-iii's check 9 — start a shell, switch organisation, run a command in a
// new pane — cannot be written at all against a fixture holding one org, and
// it is the check covering the defect where a switch silently stopped every
// later command being journalled.
func TestSeedRegistersTheSecondOrgProductionCanSwitchTo(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	if seeded.SecondOrg == "" {
		t.Fatal("the default seed must lay down a second org for the switch checks")
	}
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.SecondOrg)

	org, err := wakilcore.LoadOrgFor(seeded.SecondOrg)
	if err != nil {
		t.Fatalf("LoadOrgFor(%q): %v", seeded.SecondOrg, err)
	}
	if org.DefaultProvider == "" {
		t.Errorf("the second org must carry a default provider; got %+v", org)
	}
	// A switch target with no project would open on an org holding nothing,
	// which is a different state from the one the check means to walk.
	registry, err := wakilcore.LoadRegistry()
	if err != nil {
		t.Fatalf("LoadRegistry(%q): %v", seeded.SecondOrg, err)
	}
	if len(registry) == 0 {
		t.Errorf("the second org must hold a project; got %+v", registry)
	}
}

// The org the instance OPENS on is still the first one. The second exists to
// be switched to, and a seed that left it active would change what every
// other seeded check is looking at.
func TestSeedLeavesTheFirstOrgActive(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())

	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)
	active, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if !strings.Contains(active.Project, seeded.Project) {
		t.Fatalf("want the first org's project active, got %q", active.Project)
	}
}

// **A failure seeding the second org must still leave WAKIL_ORG on the
// first.** Found by review: the restore used to run only after a successful
// seed, so a failure left this process pointed at the second org with no
// restore in anyone's hands — `enterFixtureHome`'s own deferred restore puts
// back only what IT set, which by then is the value this path overwrote.
func TestSeedSecondOrgRestoresTheFirstOrgEvenWhenItFails(t *testing.T) {
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", "first")

	// An org id wakilcore's own token pattern refuses, so seedOrgState fails
	// with WAKIL_ORG already pointed at it.
	if err := seedSecondOrg(fixture, "first", SeedSpec{
		Org: "not a valid org id", DisplayName: "x", Provider: "p",
		Project: "j", Environment: "staging",
	}); err == nil {
		t.Fatal("want the seed to fail")
	}
	if got := os.Getenv("WAKIL_ORG"); got != "first" {
		t.Fatalf("WAKIL_ORG must be back on the first org, got %q", got)
	}
}

// The second org's name is derived in one place and written literally in the
// check file, because a .jsonl has no interpolation. This ties the two, so a
// change to the derivation fails here rather than in a live GUI run.
func TestTheSwitchCheckNamesTheOrgTheSeedDerives(t *testing.T) {
	second := DefaultSeed().second().Org
	body, err := os.ReadFile("../checks/seeded/2c-iii-7-org-switch.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "org.row."+second+".switch") {
		t.Fatalf("the switch check must click org.row.%s.switch; it does not", second)
	}
}

// The bookings database is a real SQLite file a DB pane can hold a row
// from, seeded with a demo booking whose id is the integer 8842 and whose
// booking_id column carries the human-facing "BK-2026-8842" — the two must
// not be conflated.
func TestSeedWritesTheBookingsDatabase(t *testing.T) {
	root := t.TempDir()
	if err := seedBookings(root); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(root, FixtureBookingsFile))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var bookingID string
	// The demo row: a hole named `id` must take 8842 and never BK-2026-8842.
	if err := db.QueryRow(`SELECT booking_id FROM bookings WHERE id = 8842`).Scan(&bookingID); err != nil {
		t.Fatal(err)
	}
	if bookingID != "BK-2026-8842" {
		t.Fatalf("booking_id = %q", bookingID)
	}
	var count int
	_ = db.QueryRow(`SELECT count(*) FROM bookings`).Scan(&count)
	if count != 2 {
		t.Fatalf("rows = %d, want 2", count)
	}
}

// The cells database carries the three awkward cells the row detail strip's
// checks open: a NULL, a 5,000-key JSON object and a 1 MiB value — and a
// second seed over the first is not an error.
func TestSeedWritesTheCellsDatabase(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 2; i++ {
		if err := seedCells(root); err != nil {
			t.Fatalf("seed %d: %v", i, err)
		}
	}
	db, err := sql.Open("sqlite", filepath.Join(root, FixtureCellsFile))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var nullNotes, rows int
	if err := db.QueryRow(`SELECT count(*), sum(note IS NULL) FROM cells`).Scan(&rows, &nullNotes); err != nil {
		t.Fatal(err)
	}
	if rows != 3 || nullNotes != 1 {
		t.Fatalf("rows = %d, NULL notes = %d; want 3 and 1", rows, nullNotes)
	}
	var keys int
	if err := db.QueryRow(`SELECT count(*) FROM json_each((SELECT doc FROM cells WHERE id = 2))`).Scan(&keys); err != nil {
		t.Fatal(err)
	}
	if keys != CellsJSONKeys {
		t.Fatalf("row 2's doc has %d keys, want %d", keys, CellsJSONKeys)
	}
	var big string
	if err := db.QueryRow(`SELECT big FROM cells WHERE id = 3`).Scan(&big); err != nil {
		t.Fatal(err)
	}
	if len(big) < CellsBigBytes || !strings.HasPrefix(big, "BIG-START-") || !strings.HasSuffix(big, "-BIG-END") {
		t.Fatalf("row 3's big is %d bytes, want at least %d between the markers", len(big), CellsBigBytes)
	}
}

// A second `--fixture <dir>` run must not die on a database left by the
// first, the same "from nothing" rule `Seed` already holds for ~/.wakil.
func TestSeedingBookingsTwiceIsNotAnError(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 2; i++ {
		if err := seedBookings(root); err != nil {
			t.Fatalf("seed %d: %v", i, err)
		}
	}
}

func TestSeedDeclaresASecondEnvironmentForTheSwitchCheck(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)
	resolved, err := wakilcore.Resolve()
	if err != nil {
		t.Fatal(err)
	}
	qa, ok := resolved.Project.Environments["qa"]
	if !ok || len(qa.API) != 1 || qa.API[0].Name != "catalog" ||
		qa.API[0].BaseURL != "https://catalog-qa.e2e-fixture.invalid" {
		t.Fatalf("qa = %+v", qa)
	}
	if wakilcore.EnvironmentIsProduction("qa", qa) {
		t.Fatal("qa reads as production; the switch check would raise a plane")
	}
}

func TestSeedDeclaresTheSlowEntryOnlyWithAStallOrigin(t *testing.T) {
	if names := apiNames(fixtureAPIEntries("")); strings.Contains(names, "slow") {
		t.Fatalf("slow declared with no listener: %s", names)
	}
	entries := fixtureAPIEntries("https://127.0.0.1:4711")
	if last := entries[len(entries)-1]; last.Name != "slow" || last.BaseURL != "https://127.0.0.1:4711" {
		t.Fatalf("slow = %+v", last)
	}
}

func apiNames(entries []wakilcore.ApiConfig) string {
	var names []string
	for _, e := range entries {
		names = append(names, e.Name)
	}
	return strings.Join(names, ",")
}

// The git project (3a-i) is seeded beside the active one, never as it: its
// two repositories carry the states the git pane's checks read, and the
// plain project directory is not a repository.
func TestSeedLaysDownTheGitProject(t *testing.T) {
	fixture, _ := seedInto(t, DefaultSeed())
	status := func(dir string) string {
		cmd := exec.Command("git", "-C", filepath.Join(fixture.Root, dir), "status", "--porcelain")
		cmd.Env = seedGitEnv(fixture.Root)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return "error: " + strings.TrimSpace(string(out))
		}
		return string(out)
	}
	if got, want := status(GitRootAPI), "MM app.txt\n?? BookingController.php\n?? notes\n"; got != want {
		t.Errorf("%s status = %q, want %q", GitRootAPI, got, want)
	}
	if got, want := status(GitRootPortal), " M index.txt\n"; got != want {
		t.Errorf("%s status = %q, want %q", GitRootPortal, got, want)
	}
	if got := status(GitProjectRootPlain); !strings.Contains(got, "not a git repository") {
		t.Errorf("%s should not be a repository; git status said %q", GitProjectRootPlain, got)
	}
	project, err := wakilcore.LoadProject(filepath.Join(fixture.Root, GitProjectRootPlain, ".wakil", "project.json"))
	if err != nil {
		t.Fatalf("loading the git project: %v", err)
	}
	if len(project.Roots) != 3 {
		t.Errorf("the git project has %d roots, want 3", len(project.Roots))
	}
}

// 3b-ii's fixture: `.env` and `vendor/` exist on disk and are gitignored, so the tree and ⌘P show
// them dimmed while no `git status` lists them (the test above pins that status is unchanged). The
// `bulk/` haystack is NOT in the default seed: every search over the git project would scan it.
func TestSeedGivesTheGitProjectIgnoredFilesButNoHaystack(t *testing.T) {
	fixture, _ := seedInto(t, DefaultSeed())
	api := filepath.Join(fixture.Root, GitRootAPI)
	for _, name := range []string{".env", "vendor/autoload.php"} {
		if _, err := os.Stat(filepath.Join(api, name)); err != nil {
			t.Errorf("%s/%s was not written: %v", GitRootAPI, name, err)
		}
		if out, err := seedGit(fixture, "check-ignore", "-q", name); err != nil {
			t.Errorf("%s/%s is not gitignored: %v %s", GitRootAPI, name, err, out)
		}
	}
	if _, err := os.Stat(filepath.Join(api, "bulk")); !os.IsNotExist(err) {
		t.Errorf("the default seed wrote bulk/ (stat: %v); only a launch that asks for the haystack gets it", err)
	}
}

// With SearchHaystack, `bulk/` is committed: the search-Cancel check's haystack, clean, every file
// under the 2 MB cap search skips above, and matching no other check's query — the replace-Cancel
// check's one-line marker included.
func TestSeedWritesTheSearchHaystackOnlyWhenAsked(t *testing.T) {
	spec := DefaultSeed()
	spec.SearchHaystack = true
	fixture, _ := seedInto(t, spec)
	api := filepath.Join(fixture.Root, GitRootAPI)
	tracked, err := seedGit(fixture, "ls-files", "bulk")
	if err != nil {
		t.Fatalf("git ls-files bulk: %v %s", err, tracked)
	}
	if got := len(strings.Fields(tracked)); got != searchBulkFiles+1 {
		t.Errorf("bulk/ has %d committed files, want %d", got, searchBulkFiles+1)
	}
	if !slices.Contains(strings.Fields(tracked), "bulk/zz-marker.txt") {
		t.Errorf("bulk/zz-marker.txt is not committed: %q", tracked)
	}
	marker, err := os.ReadFile(filepath.Join(api, "bulk", "zz-marker.txt"))
	if err != nil || string(marker) != "replace-marker-qz7\n" {
		t.Errorf("bulk/zz-marker.txt = %q, %v", marker, err)
	}
	if out, _ := seedGit(fixture, "status", "--porcelain"); strings.Contains(out, "bulk") {
		t.Errorf("bulk/ shows in git status: %q", out)
	}
	body, err := os.ReadFile(filepath.Join(api, "bulk", "199.txt"))
	if err != nil {
		t.Fatalf("reading bulk/199.txt: %v", err)
	}
	if len(body) < searchBulkBytes/2 || len(body) >= 2<<20 {
		t.Errorf("bulk/199.txt is %d bytes, want about 1 MiB and under search's 2 MB cap", len(body))
	}
	for _, text := range []string{string(body), string(marker)} {
		for _, query := range []string{"needle", "book", "line", "portal", ".env", "zq"} {
			if strings.Contains(strings.ToLower(text), query) {
				t.Errorf("bulk/ matches %q, another check's query", query)
			}
		}
	}
}

// Only the search-Cancel and replace-Cancel checks' launches ask for the haystack.
func TestOnlyTheSearchCancelCheckWantsTheHaystack(t *testing.T) {
	if !WantsSearchHaystack([]Check{{Name: "3b-ii-search-cancel.jsonl"}}) {
		t.Error("3b-ii-search-cancel.jsonl does not get the haystack")
	}
	if !WantsSearchHaystack([]Check{{Name: "3b-ii-b-replace-cancel.jsonl"}}) {
		t.Error("3b-ii-b-replace-cancel.jsonl does not get the haystack")
	}
	if WantsSearchHaystack([]Check{{Name: "3b-ii-search.jsonl"}, {Name: "3a-i-git-list.jsonl"}}) {
		t.Error("a check that never cancels a search gets the haystack")
	}
}

// With GitHook, e2e-portal carries an executable pre-commit hook that refuses a commit in its own
// words, and the seed's commit still happened; without it, no hook is written.
func TestSeedWritesTheFailingHookOnlyWhenAsked(t *testing.T) {
	plain, _ := seedInto(t, DefaultSeed())
	if _, err := os.Stat(filepath.Join(plain.Root, GitRootPortal, ".git", "hooks", "pre-commit")); !os.IsNotExist(err) {
		t.Errorf("the default seed wrote a pre-commit hook (stat: %v); only the hook check's launch gets it", err)
	}

	spec := DefaultSeed()
	spec.GitHook = true
	fixture, _ := seedInto(t, spec)
	portal := filepath.Join(fixture.Root, GitRootPortal)
	info, err := os.Stat(filepath.Join(portal, ".git", "hooks", "pre-commit"))
	if err != nil || info.Mode()&0o111 == 0 {
		t.Fatalf("pre-commit hook: %v, mode %v; want an executable hook", err, info)
	}
	git := func(args ...string) (string, error) {
		cmd := exec.Command("git", append([]string{"-C", portal}, args...)...)
		cmd.Env = seedGitEnv(fixture.Root)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := git("log", "--format=%s"); err != nil || strings.TrimSpace(out) != "seed" {
		t.Errorf("e2e-portal's history = %q, %v; want the one seed commit", out, err)
	}
	out, err := git("commit", "-qam", "refused")
	if err == nil || !strings.Contains(out, "e2e hook says no") {
		t.Errorf("a commit under the hook = %q, %v; want it refused with 'e2e hook says no'", out, err)
	}
	if !WantsGitHook([]Check{{Name: "3a-ii-hook-fails.jsonl"}}) || WantsGitHook([]Check{{Name: "3a-ii-commit.jsonl"}}) {
		t.Error("WantsGitHook must be true for 3a-ii-hook-fails.jsonl only")
	}
}

// seedGit runs git in the fixture's e2e-api repository, with the seed's own environment.
func seedGit(fixture Fixture, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", filepath.Join(fixture.Root, GitRootAPI)}, args...)...)
	cmd.Env = seedGitEnv(fixture.Root)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// The rootless project is there to switch TO (80c97d7: the "no project root"
// note is derived from the live context). It must load, declare no roots, and
// never be the project a launch opens on.
func TestTheRootlessProjectIsRegisteredAndNotActive(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)

	registry, err := wakilcore.LoadRegistryFor(seeded.Org)
	if err != nil {
		t.Fatal(err)
	}
	entry, ok := registry["e2e-rootless"]
	if !ok {
		t.Fatalf("no e2e-rootless in %v", registry)
	}
	project, err := wakilcore.LoadProject(entry.Path)
	if err != nil {
		t.Fatal(err)
	}
	if len(project.Roots) != 0 {
		t.Fatalf("roots %v", project.Roots)
	}
	active, err := wakilcore.ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if active.Project != registry[seeded.Project].Path {
		t.Fatalf("active project %q, want %s's", active.Project, seeded.Project)
	}
}

// The spare account is what USE switches to (#331, 2c-iv W1). It exists only
// with the scripted agent, so every other launch lists the accounts it always
// has, and it is never the org's default.
func TestTheSpareAccountExistsOnlyWithTheAgent(t *testing.T) {
	fixture, seeded := seedInto(t, DefaultSeed())
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)
	if _, err := wakilcore.LoadProviderFor(seeded.Org, "e2e-provider-spare"); err == nil {
		t.Fatal("a launch with no agent has a spare account")
	}
	if seeded.SpareProvider != "" {
		t.Fatalf("SpareProvider = %q", seeded.SpareProvider)
	}

	spec := DefaultSeed()
	spec.AgentBinary = "/bin/true"
	spec.SpareProvider = "e2e-provider-spare"
	fixture, seeded = seedInto(t, spec)
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", seeded.Org)
	spare, err := wakilcore.LoadProviderFor(seeded.Org, "e2e-provider-spare")
	if err != nil {
		t.Fatal(err)
	}
	if spare.ClaudePath != "/bin/true" || seeded.SpareProvider != "e2e-provider-spare" {
		t.Fatalf("spare %+v, seeded %+v", spare, seeded)
	}
	org, err := wakilcore.LoadOrgFor(seeded.Org)
	if err != nil {
		t.Fatal(err)
	}
	if org.DefaultProvider != "e2e-provider" {
		t.Fatalf("default provider %q", org.DefaultProvider)
	}
}

// The spare account rides only on a launch that carries the agent: every
// seeded check's account rows and binding counts were written against two
// accounts in this org, not three (review C1).
func TestOnlyALaunchWithTheAgentSeedsTheSpareAccount(t *testing.T) {
	if got := SpareProviderFor(""); got != "" {
		t.Fatalf("a launch with no agent seeds spare account %q", got)
	}
	if got := SpareProviderFor("/fixture/bin/wakil-e2e-agent"); got != "e2e-provider-spare" {
		t.Fatalf("a launch with the agent seeds %q", got)
	}
}

// With CloneFolder, the organisation's last clone folder is e2e-clones/ under the fixture root, and
// it exists; without it, the organisation records none.
func TestSeedRecordsTheCloneFolderOnlyWhenAsked(t *testing.T) {
	plain, _ := seedInto(t, DefaultSeed())
	if org := loadSeededOrg(t, plain, DefaultSeed().Org); org.LastCloneFolder != "" {
		t.Errorf("the default seed recorded a clone folder %q; only the clone check's launch gets one", org.LastCloneFolder)
	}
	spec := DefaultSeed()
	spec.CloneFolder = true
	fixture, _ := seedInto(t, spec)
	org := loadSeededOrg(t, fixture, spec.Org)
	want := filepath.Join(fixture.Root, CloneFolderName)
	if org.LastCloneFolder != want {
		t.Errorf("lastCloneFolder = %q, want %q", org.LastCloneFolder, want)
	}
	if info, err := os.Stat(want); err != nil || !info.IsDir() {
		t.Errorf("the clone folder is not a directory: %v", err)
	}
	if !WantsCloneFolder([]Check{{Name: "3a-iii-add-project-clone.jsonl"}}) || WantsCloneFolder([]Check{{Name: "3a-ii-commit.jsonl"}}) {
		t.Error("WantsCloneFolder must be true for 3a-iii-add-project-clone.jsonl only")
	}
}

// loadSeededOrg reads one seeded organisation back through production's reader.
func loadSeededOrg(t *testing.T, fixture Fixture, org string) wakilcore.Org {
	t.Helper()
	t.Setenv("HOME", fixture.Home)
	t.Setenv("WAKIL_ORG", org)
	o, err := wakilcore.LoadOrgFor(org)
	if err != nil {
		t.Fatalf("LoadOrgFor(%q): %v", org, err)
	}
	return *o
}

// TestBrowserSitesSeedOnlyForItsChecks — with BrowserSites, staging gains `pages` (the stub's
// origin) and `e2e-live` is registered, never active, whose `live` environment loads as production
// with a `site` entry on localhost; without it the seed is the default one.
func TestBrowserSitesSeedOnlyForItsChecks(t *testing.T) {
	const stub = "http://127.0.0.1:4321"
	read := func(fixture Fixture, seeded Seeded) (map[string]wakilcore.ProjectEntry, wakilcore.Project) {
		t.Setenv("HOME", fixture.Home)
		t.Setenv("WAKIL_ORG", seeded.Org)
		registry, err := wakilcore.LoadRegistry()
		if err != nil {
			t.Fatal(err)
		}
		active := registry[seeded.Project]
		project, err := wakilcore.LoadProject(active.Path)
		if err != nil {
			t.Fatal(err)
		}
		return registry, *project
	}

	plainFixture, plainSeeded := seedInto(t, DefaultSeed())
	registry, project := read(plainFixture, plainSeeded)
	if _, there := registry[LiveProjectName]; there {
		t.Error("the default seed registers e2e-live")
	}
	if got := len(project.Environments["staging"].API); got != 2 {
		t.Errorf("the default staging declares %d api entries, want 2 (no stall origin here)", got)
	}

	spec := DefaultSeed()
	spec.BrowserSites, spec.PageStub = true, stub
	fixture, seeded := seedInto(t, spec)
	registry, project = read(fixture, seeded)
	var pages *wakilcore.ApiConfig
	for _, entry := range project.Environments["staging"].API {
		if entry.Name == "pages" {
			entry := entry
			pages = &entry
		}
	}
	if pages == nil || pages.BaseURL != stub {
		t.Errorf("staging's pages entry = %+v, want the stub origin %s", pages, stub)
	}
	if got := len(project.Environments["staging"].API); got != 3 {
		t.Errorf("staging declares %d api entries, want the default 2 and pages", got)
	}
	entry, ok := registry[LiveProjectName]
	if !ok {
		t.Fatal("e2e-live is not in the registry")
	}
	liveP, err := wakilcore.LoadProject(entry.Path)
	if err != nil {
		t.Fatal(err)
	}
	live := *liveP
	env, ok := live.Environments["live"]
	if !ok || !wakilcore.EnvironmentIsProduction("live", env) {
		t.Errorf("e2e-live's live environment = %+v, want one that loads as production", env)
	}
	if len(env.API) != 1 || env.API[0].Name != "site" || env.API[0].BaseURL != "http://localhost:4321" {
		t.Errorf("e2e-live's api = %+v, want site on http://localhost:4321", env.API)
	}
	if live.Org != seeded.Org {
		t.Errorf("e2e-live's org = %q, want %q", live.Org, seeded.Org)
	}
	active, err := wakilcore.ReadActive()
	if err != nil || !strings.Contains(active.Project, seeded.Project) || strings.Contains(active.Project, LiveProjectName) {
		t.Errorf("the active project = %q, %v; e2e-live must never be active", active.Project, err)
	}

	for _, name := range []string{"3c-ii-tags.jsonl", "3c-ii-production.jsonl"} {
		if !WantsBrowserSites([]Check{{Name: name}}) {
			t.Errorf("WantsBrowserSites(%s) = false", name)
		}
	}
	for _, name := range []string{"3c-ii-other.jsonl", "3c-i-browser.jsonl", "3c-ii-tags"} {
		if WantsBrowserSites([]Check{{Name: name}}) {
			t.Errorf("WantsBrowserSites(%s) = true; only the tags and production checks get the sites", name)
		}
	}

	bad := DefaultSeed()
	bad.BrowserSites = true
	if _, err := Seed(mustFixture(t), bad); err == nil {
		t.Error("BrowserSites without a page stub origin must be refused")
	}
}

func mustFixture(t *testing.T) Fixture {
	t.Helper()
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return fixture
}
