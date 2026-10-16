package driver

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/yehia-khalil/wakil/internal/wakilcore"

	_ "modernc.org/sqlite"
)

// SeedSpec names the state one fixture launch opens onto.
//
// **The fixture is seeded state, not only a HOME** (spec §6.1, corrected by
// the probe). A fresh fixture HOME opens on the organisation plane — nine
// elements, one anonymous button, "NO ORGANISATION IS OPEN · NOTHING BEHIND
// THIS PLANE" — because reaching anything else needs an org, a project and an
// environment already on disk. So this is not a convenience: without it no
// check can get past that plane.
type SeedSpec struct {
	Org         string
	DisplayName string
	Provider    string
	Project     string
	Environment string
	// StallOrigin is the baseUrl of the fixture's `slow` entry: a `StallListener`
	// the session started. Empty declares no `slow` entry.
	StallOrigin string
	// AgentBinary is what the provider record names as its agent — the
	// absolute path the window launches for a turn.
	//
	// **Seeded onto the record, never put on `PATH`.** `executableURL` does
	// not search `PATH`, and #238's rule is that the resolved path travels on
	// the provider row as "the only absolute path the app has". So a stub
	// named here runs the production resolution path — listing, row,
	// credentials, `buildLaunch` — and an unwired dependency still fails the
	// check.
	//
	// Empty leaves the record without one, which is every check that does not
	// drive the agent: `decodeProviderCredentials` refuses an empty
	// `claudePath`, so those windows open with no agent and say so, exactly as
	// they did before this field existed.
	AgentBinary string
	// GitProject names a second project in this org whose roots are git
	// repositories (3a-i's git pane), laid down by `seedGitProject`. Empty
	// seeds none — the second org's case. It is never the active project:
	// a check that wants it switches with `ctx_set_project`, so every check
	// written before it opens onto exactly the state it was written against.
	GitProject string
	// AgentScript is the file copied into the provider's config directory for
	// the stub to answer from. The config directory is the only channel that
	// reaches the agent child, because `buildLaunch` builds its environment
	// from a whitelist of four keys (Decision 16).
	AgentScript string
	// SearchHaystack commits `bulk/` (200 × 1 MiB, and one marker line) into the git project's
	// e2e-api, so a regex search or replace is still running when a press on Cancel lands. **Only the
	// search-Cancel and replace-Cancel checks' launches ask for it** (`WantsSearchHaystack`): every search over the git project would otherwise scan it, and a
	// parity step could settle on a search still in flight.
	SearchHaystack bool
	// RootlessProject names a project in this org whose project.json declares
	// no roots. Never active: a check switches to it with `ctx_set_project`,
	// which is how the "no project root" note — derived from the live context
	// since 80c97d7 — is observable at all. Empty seeds none.
	RootlessProject string
	// SpareProvider names a second account in this org, with the same agent
	// binary and its own config dir and stored credential, for USE to switch
	// to (#331, 2c-iv W1). Seeded only with the scripted agent, because USE
	// refuses an account with no claude path or credential. Never the default.
	SpareProvider string
}

// DefaultSeed is the state every check gets unless it asks for another.
//
// The names are deliberately NOT the operator's own ("initech", "umbrella",
// "personal"): a fixture that reused them would make a stray run's output
// indistinguishable from the real store in a screenshot or a paste.
func DefaultSeed() SeedSpec {
	return SeedSpec{
		Org:         "e2e-fixture",
		DisplayName: "E2E Fixture",
		Provider:    "e2e-provider",
		Project:     "e2e-project",
		Environment: "staging",
		GitProject:  "e2e-git",
		// Never active (see the field), so every check opens as it was written.
		RootlessProject: "e2e-rootless",
	}
}

// Seeded names the state a seed wrote. It is what `Fixture.Env` reads to put
// WAKIL_ORG on the launch, and the zero value means "nothing was seeded".
//
// It deliberately carries no project.json path and no config dir. An earlier
// version did, documented "for a launch and a teardown to use", and neither
// read them — the paths are derivable and `active.json` already holds the
// project's. #254 needs the config dir to seed a login binary onto the provider
// record; it can add the field then, with a caller that reads it.
type Seeded struct {
	Org         string
	Provider    string
	Project     string
	Environment string
	// SecondOrg is the organisation a switch check switches TO. It carries
	// its own provider, project and environment, laid down by the same
	// production writers as the first.
	//
	// **A fixture holding one org cannot express an organisation switch at
	// all**, and the switch is 2c-iii's check 9 — the one covering the defect
	// where a switch silently stopped every later command being journalled.
	SecondOrg string
	// SpareProvider is the second account in the first org, when the launch
	// seeded one (SeedSpec.SpareProvider): the credential store needs its id.
	SpareProvider string
}

// Seed writes one fixture's ~/.wakil state through wakilcore's OWN writers.
//
// **Through the production writers, not by marshalling JSON here.** Three
// invariants live in those functions and nowhere else, and a second writer
// would have to re-earn each of them: `AddProvider` stores the
// `EvalSymlinks`-resolved configDir (a mismatch there produces "a fresh,
// correct sign-in that reads as logged out"), `SaveRegistry` must marshal with
// `MarshalIndent` because `RemoveOrg` decides whether an org still holds
// projects by testing projects.json against `len("{}")`, and
// `SetProjectChecked` is what knows that active.json holds the project's PATH
// rather than its name. Seeding by hand would duplicate all three silently.
//
// **HOME is overridden for the duration and restored.** wakilcore resolves
// ~/.wakil through `os.UserHomeDir()`, which on darwin is $HOME, so this is
// the only way to point the production writers at the fixture — and it is
// also the whole risk: the same call with HOME unset writes into the
// operator's real store, which is the global "never touch the real ~/.wakil"
// constraint. `guardFixtureHome` is why that cannot happen quietly.
func Seed(fixture Fixture, spec SeedSpec) (Seeded, error) {
	if err := spec.validate(); err != nil {
		return Seeded{}, err
	}
	restore, err := enterFixtureHome(fixture, spec.Org)
	if err != nil {
		return Seeded{}, err
	}
	defer restore()

	seeded := Seeded{
		Org:           spec.Org,
		Provider:      spec.Provider,
		Project:       spec.Project,
		Environment:   spec.Environment,
		SpareProvider: spec.SpareProvider,
	}

	// **"From nothing" made literal, so a second run against one `--fixture`
	// directory works.** `CreateOrg` refuses an org that already exists, which
	// made the runner's own `--fixture <dir>` flag single-use: the second run
	// died with `org "e2e-fixture" already exists`, which is a confusing failure
	// for the one flag whose purpose is reuse. Removing the tree is safe
	// precisely because `guardFixtureHome` has already established that this
	// home is a real directory inside the fixture root — this is the one delete
	// in the harness, and it is gated on the same check that lets the writes
	// happen at all.
	if err := os.RemoveAll(filepath.Join(fixture.Home, ".wakil")); err != nil {
		return Seeded{}, fmt.Errorf("seed: clearing the fixture's previous state: %w", err)
	}

	// **The second organisation is seeded after the first, and the first is
	// left active.** A fixture holding one org cannot express an organisation
	// switch at all, and the switch is 2c-iii's check 9 — the check covering
	// the defect where a switch silently stopped every later command being
	// journalled. The second is laid down by the same production writers, so
	// it is a real org and not a row in a list.
	if err := seedOrgState(fixture, spec); err != nil {
		return Seeded{}, err
	}
	if err := seedBookings(fixture.Root); err != nil {
		return Seeded{}, err
	}
	if err := seedCells(fixture.Root); err != nil {
		return Seeded{}, err
	}
	second := spec.second()
	if err := seedSecondOrg(fixture, spec.Org, second); err != nil {
		return Seeded{}, err
	}
	seeded.SecondOrg = second.Org
	return seeded, nil
}

// seedSecondOrg writes the second organisation with WAKIL_ORG pointed at it,
// and points it back at the first **on every path out, including the failing
// ones**.
//
// **A deferred restore, not a trailing Setenv.** The first version restored
// after `seedOrgState` returned, so a failure seeding the second org left this
// process with the second org ambient and no restore in anyone's hands — and
// `enterFixtureHome`'s own deferred restore only puts back what IT set, which
// by then is the value this function overwrote. That is the same leak
// `enterFixtureHome` exists to prevent, arriving one level down; the comment
// here used to claim the leak was prevented while the code allowed it.
func seedSecondOrg(fixture Fixture, first string, second SeedSpec) (err error) {
	if setErr := os.Setenv("WAKIL_ORG", second.Org); setErr != nil {
		return setErr
	}
	defer func() {
		if restoreErr := os.Setenv("WAKIL_ORG", first); restoreErr != nil && err == nil {
			err = restoreErr
		}
	}()
	if seedErr := seedOrgState(fixture, second); seedErr != nil {
		// No "seed:" prefix — `seedOrgState`'s own errors already carry one,
		// and wrapping produced `seed: the second org: seed: creating org …`.
		return fmt.Errorf("the second org: %w", seedErr)
	}
	return nil
}

// second is the organisation a switch check switches TO.
//
// Derived from the first rather than configured, so that a caller cannot seed
// a fixture with only one org by forgetting a field — the switch checks would
// then fail on the fixture rather than on the app.
func (s SeedSpec) second() SeedSpec {
	return SeedSpec{
		Org:         s.Org + "-two",
		DisplayName: s.DisplayName + " Two",
		Provider:    s.Provider + "-two",
		Project:     s.Project + "-two",
		Environment: s.Environment,
	}
}

// seedOrgState writes one organisation's worth of state.
//
// **HOME and WAKIL_ORG must already point at the fixture and at this org** —
// every wakilcore writer below resolves its paths through them, and
// `enterFixtureHome` is the one place that is established.
func seedOrgState(fixture Fixture, spec SeedSpec) error {
	// **The org is created WITHOUT its default provider, and gains it later.**
	// Not an ordering preference: `CreateOrg` validates `DefaultProvider`
	// against the org's registered providers and refuses an unknown one, while
	// `AddProvider` needs the org directory to exist first. The two constraints
	// only compose in this order — create, add the provider, then set the
	// default. Measured, not reasoned: the first version set it here and
	// `CreateOrg` answered "no provider \"e2e-provider\" in org
	// \"e2e-fixture\"".
	if err := wakilcore.CreateOrg(spec.Org, wakilcore.Org{
		DisplayName: spec.DisplayName,
	}); err != nil {
		return fmt.Errorf("seed: creating org %q: %w", spec.Org, err)
	}

	// The config dir is a real directory inside the fixture: `AddProvider`
	// requires one to exist for a claude-code provider. This is the "Claude
	// config dirs" half of #248's fixture contract, and it is seeded onto the
	// record rather than exported as CLAUDE_CONFIG_DIR because `CurrentOrg` has
	// deliberately no fallback to that variable (paths.go) — the config dir
	// travels on the provider record and nowhere else.
	configDir := filepath.Join(fixture.Root, "claude-"+spec.Provider)
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return fmt.Errorf("seed: making the provider config dir: %w", err)
	}
	if spec.AgentScript != "" {
		if err := copyFile(spec.AgentScript, filepath.Join(configDir, AgentScriptFile)); err != nil {
			return fmt.Errorf("seed: laying down the agent script: %w", err)
		}
	}
	if err := wakilcore.AddProvider(spec.Org, wakilcore.Provider{
		ID:         spec.Provider,
		Kind:       wakilcore.ProviderKindClaudeCode,
		Label:      "E2E fixture account",
		ConfigDir:  configDir,
		ClaudePath: spec.AgentBinary,
	}); err != nil {
		return fmt.Errorf("seed: adding provider %q: %w", spec.Provider, err)
	}
	// Read back rather than assumed: this is what proves `AddProvider` wrote a
	// record production can load, and it is the same "assert the effect, never
	// the call" rule the rest of the harness holds itself to.
	if _, err := wakilcore.LoadProviderFor(spec.Org, spec.Provider); err != nil {
		return fmt.Errorf("seed: reading back provider %q: %w", spec.Provider, err)
	}
	if spec.SpareProvider != "" {
		if err := seedSpareProvider(fixture, spec); err != nil {
			return err
		}
	}

	// Now that the provider exists, the org may name it as its default — see
	// the ordering note above `CreateOrg`.
	if err := wakilcore.SaveOrg(spec.Org, wakilcore.Org{
		DisplayName:     spec.DisplayName,
		DefaultProvider: spec.Provider,
	}); err != nil {
		return fmt.Errorf("seed: setting the org's default provider: %w", err)
	}

	// The project's own working tree, with its project.json under `.wakil/`
	// exactly as an operator's would be. `roots` matters beyond tidiness:
	// `WindowSession` launches into `RootPaths.first` and falls back to
	// `NSHomeDirectory()` when there is none.
	projectDir := filepath.Join(fixture.Root, spec.Project)
	if err := os.MkdirAll(filepath.Join(projectDir, ".wakil"), 0o755); err != nil {
		return fmt.Errorf("seed: making the project directory: %w", err)
	}
	projectFile := filepath.Join(projectDir, ".wakil", "project.json")
	// **Marshalled here rather than through a production writer, because on
	// `main` there is no `project.json` writer at all** — the file is
	// hand-authored (docs/wakil/operator-todo.md), and `SaveProject` arrived
	// on the unmerged #207/#238 branch. `LoadProject` below is the production
	// reader, so the shape is still checked by production code rather than by
	// this function's own opinion of it.
	//
	// `production` is left ABSENT rather than written `false`. The field is a
	// `*bool` precisely because absent is not false (config.go), and the
	// environment is named "staging", which `EnvironmentIsProduction` does not
	// treat as production. Writing an explicit `false` would seed a
	// *deliberate disarm* — a different and much louder claim than "this is an
	// ordinary staging environment".
	project := wakilcore.Project{
		Name:  spec.Project,
		Org:   spec.Org,
		Roots: []wakilcore.Root{{Path: projectDir}},
		Environments: map[string]wakilcore.Environment{
			spec.Environment: {
				Databases: []wakilcore.Database{},
				API:       fixtureAPIEntries(spec.StallOrigin),
			},
			// A second environment, for W1's round-trip switch. It declares catalog under its
			// own origin, and no billing, so a switch shows both re-resolution (a new origin)
			// and the name kept with nothing behind it. Not production by name, and no flag.
			"qa": {
				Databases: []wakilcore.Database{},
				API: []wakilcore.ApiConfig{
					{Name: "catalog", BaseURL: "https://catalog-qa.e2e-fixture.invalid"},
				},
			},
		},
	}
	encoded, err := json.MarshalIndent(project, "", "  ")
	if err != nil {
		return fmt.Errorf("seed: encoding project.json: %w", err)
	}
	if err := os.WriteFile(projectFile, append(encoded, '\n'), 0o644); err != nil {
		return fmt.Errorf("seed: writing project.json: %w", err)
	}
	if _, err := wakilcore.LoadProject(projectFile); err != nil {
		return fmt.Errorf("seed: the project.json just written is not loadable: %w", err)
	}

	registry := map[string]wakilcore.ProjectEntry{
		spec.Project: {Path: projectFile, Provider: spec.Provider},
	}
	if spec.GitProject != "" {
		gitProjectFile, err := seedGitProject(fixture.Root, spec)
		if err != nil {
			return err
		}
		registry[spec.GitProject] = wakilcore.ProjectEntry{Path: gitProjectFile, Provider: spec.Provider}
	}
	if spec.RootlessProject != "" {
		rootlessFile, err := seedRootlessProject(fixture.Root, spec)
		if err != nil {
			return err
		}
		registry[spec.RootlessProject] = wakilcore.ProjectEntry{Path: rootlessFile, Provider: spec.Provider}
	}
	if err := wakilcore.SaveRegistry(spec.Org, registry); err != nil {
		return fmt.Errorf("seed: writing the project registry: %w", err)
	}

	// **`SetProjectChecked`, not a hand-written active.json.** It is what knows
	// that `active.Project` holds the project's PATH rather than its name, and
	// it re-checks the project's declared org against the ambient one — the
	// cross-org boundary. A seed that wrote the name would produce a perfectly
	// readable active.json that `Resolve()` then refused.
	if err := wakilcore.SetProjectChecked(spec.Project); err != nil {
		return fmt.Errorf("seed: setting the active project: %w", err)
	}

	// The environment and the provider pick go on last, because
	// `SetProjectChecked` blanks `Environment` when the incoming project does
	// not declare it — so anything written before it would be discarded.
	active, err := wakilcore.ReadActive()
	if err != nil {
		return fmt.Errorf("seed: reading the active context back: %w", err)
	}
	active.Environment = spec.Environment
	active.Provider = spec.Provider
	if err := wakilcore.WriteActive(active); err != nil {
		return fmt.Errorf("seed: writing the active context: %w", err)
	}

	return nil
}

// fixtureAPIEntries are the environment's `api[]` entries, and **two of them
// on purpose** (#296).
//
// Until this existed the fixture declared none, so `list_apis` answered with
// an empty list and `api_open` refused every call with `noEntries` — the api
// pane could not be reached by a check at all, whatever the check asked for.
// That is why it is seeded here rather than by the one check that wants it:
// the pane's whole surface is behind this.
//
// **Two rather than one, because the interesting assertions are differences.**
// One entry makes `api_open {}` resolve and proves nothing else. Two make
// three separate things observable, none of which a single entry can show:
//
//   - `billing` carries an `authRef` and `catalog` does not, so `credentialed`
//     differs between them — and with it the `authorization` row of
//     `apiHeaderRegion`, which is drawn only for a credentialed entry. A
//     re-point from one to the other is a header region that visibly changes
//     class, which is #158's three classes executed rather than asserted.
//   - `api_set_request {entry: …}` re-points a draft, and a re-point with one
//     entry to choose from lands where it started.
//   - a bare `api_open {}` is `ambiguousEntry` rather than a guess, which is
//     `pickApiEntry`'s load-bearing refusal: the pane opened against a guessed
//     entry is the one whose next send carries one backend's credential to
//     another backend's host.
//
// **The `authRef` names no real secret**, and `credentialed` is derived from
// the ref being PRESENT rather than from resolving it (`ApiInfo.Authenticated`)
// — so a ref that resolves to nothing is exactly the state the boolean is
// documented to describe.
//
// **What that costs, now that checks DO send** (2c-iv's surface): a send from
// `billing` is refused by Go before it reaches the wire — "no credential
// stored for ref e2e-billing-token" — which is a correct refusal and not a
// transport failure. A check that wants a send to actually leave uses
// `catalog`, which declares no ref. This sentence used to begin "Nothing in
// these checks sends a request", which stopped being true.
//
// `slow` is the third, and the only one whose host answers, by never
// answering (W14).
func fixtureAPIEntries(stallOrigin string) []wakilcore.ApiConfig {
	entries := []wakilcore.ApiConfig{
		{Name: "billing", BaseURL: "https://billing.e2e-fixture.invalid", AuthRef: "e2e-billing-token"},
		{Name: "catalog", BaseURL: "https://catalog.e2e-fixture.invalid"},
	}
	if stallOrigin != "" {
		entries = append(entries, wakilcore.ApiConfig{Name: "slow", BaseURL: stallOrigin})
	}
	return entries
}

// FixtureBookingsFile is the SQLite database `seedBookings` writes at the
// fixture root, for a check to point a DB pane at with `db_set_dsn`.
const FixtureBookingsFile = "bookings.db"

// seedBookings writes a small SQLite database at
// `<fixture root>/bookings.db`, holding a table a DB pane can list and a row
// a check can drop onto an api pane.
//
// **The DSN is not stored here.** Amendment 1: the fixture keychain is
// recreated at launch, after `Seed` runs, so anything this function stored
// now would be wiped before the app ever read it — a check stores the DSN
// itself, by dispatching `db_set_dsn`, once the keychain it lands in exists.
func seedBookings(root string) error {
	path := filepath.Join(root, FixtureBookingsFile)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("seed: clearing the previous bookings database: %w", err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return fmt.Errorf("seed: opening the bookings database: %w", err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE bookings(id INTEGER PRIMARY KEY, booking_id TEXT, status TEXT)`); err != nil {
		return fmt.Errorf("seed: creating the bookings table: %w", err)
	}
	if _, err := db.Exec(`INSERT INTO bookings(id, booking_id, status) VALUES (8842, 'BK-2026-8842', 'held'), (8843, 'BK-2026-8843', 'confirmed')`); err != nil {
		return fmt.Errorf("seed: inserting demo bookings: %w", err)
	}
	return nil
}

// FixtureCellsFile is the SQLite database `seedCells` writes at the fixture
// root: a table whose cells are awkward on purpose, for the DB pane's row
// detail strip.
const FixtureCellsFile = "cells.db"

// CellsJSONKeys is how many keys row 2's `doc` holds. Pretty-printed by the
// strip, it is one line per key plus the two braces — the 5,000-line JSON
// cell the DB pane copy/cancel/detail spec names.
const CellsJSONKeys = 5000

// CellsBigBytes is the length of the run between row 3's `big` markers — the
// spec's 1 MB cell.
const CellsBigBytes = 1 << 20

// seedCells writes `<fixture root>/cells.db` with one table, `cells`:
//
//   - row 1, `small`: `note` is NULL and `doc` is `{"b":2,"a":1}`, which the
//     strip pretty-prints with sorted keys as `"a" : 1` — a line that exists
//     only in the strip, because the grid and the row's accessibility label
//     carry the compact text.
//   - row 2, `json-5000`: `doc` is a compact object of keys k0000…k4999, so
//     the strip's LAST line, `"k4999" : 4999`, is what shows a value drawn
//     whole (Interaction Rule 8).
//   - row 3, `one-megabyte`: `big` is 1 MiB with no break point between
//     `BIG-START-` and `-BIG-END`, and `doc` is `{"c":3}`.
//
// A file of its own rather than a table in bookings.db, so no check written
// against bookings — a table list, a palette search — sees anything new. Like
// `seedBookings`, it stores no DSN; a check dispatches `db_set_dsn`.
func seedCells(root string) error {
	path := filepath.Join(root, FixtureCellsFile)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("seed: clearing the previous cells database: %w", err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return fmt.Errorf("seed: opening the cells database: %w", err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE cells(id INTEGER PRIMARY KEY, label TEXT, note TEXT, doc TEXT, big TEXT)`); err != nil {
		return fmt.Errorf("seed: creating the cells table: %w", err)
	}
	var doc strings.Builder
	doc.WriteString("{")
	for i := 0; i < CellsJSONKeys; i++ {
		if i > 0 {
			doc.WriteString(",")
		}
		fmt.Fprintf(&doc, `"k%04d":%d`, i, i)
	}
	doc.WriteString("}")
	big := "BIG-START-" + strings.Repeat("0123456789abcdef", CellsBigBytes/16) + "-BIG-END"
	if _, err := db.Exec(
		`INSERT INTO cells(id, label, note, doc, big) VALUES
			(1, 'small', NULL, '{"b":2,"a":1}', 'short'),
			(2, 'json-5000', 'n2', ?, 'short'),
			(3, 'one-megabyte', 'n3', '{"c":3}', ?)`,
		doc.String(), big); err != nil {
		return fmt.Errorf("seed: inserting the cells rows: %w", err)
	}
	return nil
}

// validate refuses a spec that would produce state nothing can load. The org
// and provider ids must match wakilcore's own token pattern, which its
// writers enforce anyway — this only makes the refusal name the field.
func (s SeedSpec) validate() error {
	for _, field := range []struct{ name, value string }{
		{"Org", s.Org},
		{"DisplayName", s.DisplayName},
		{"Provider", s.Provider},
		{"Project", s.Project},
		{"Environment", s.Environment},
	} {
		if strings.TrimSpace(field.value) == "" {
			return fmt.Errorf("seed: SeedSpec.%s is empty", field.name)
		}
	}
	return nil
}

// enterFixtureHome points HOME (and WAKIL_ORG, which CurrentOrg reads and
// nothing else supplies) at the fixture, and returns the restore.
//
// **The guard is the point.** Every wakilcore writer below resolves its path
// from HOME, so this function is the one place where "the seed writes into the
// fixture" is true or false. It refuses rather than trusts: a fixture whose
// home is not under its own root is a bug that would otherwise surface as the
// operator's own ~/.wakil quietly gaining an "e2e-fixture" org.
func enterFixtureHome(fixture Fixture, org string) (func(), error) {
	if err := guardFixtureHome(fixture); err != nil {
		return nil, err
	}
	previousHome, hadHome := os.LookupEnv("HOME")
	previousOrg, hadOrg := os.LookupEnv("WAKIL_ORG")
	restore := func() {
		restoreEnv("HOME", previousHome, hadHome)
		restoreEnv("WAKIL_ORG", previousOrg, hadOrg)
	}
	// **`restore` is built before the first `Setenv` and run on the way out of
	// every failure below.** The previous version returned `nil, err` between
	// the two assignments, which left HOME pointing at the fixture with no
	// restore in the caller's hands — so a later wakilcore call in this process
	// would resolve ~/.wakil inside a fixture teardown then deletes, and
	// `TestSeedRestoresTheEnvironmentItOverrode` asserted that could not happen
	// while this path made it possible.
	if err := os.Setenv("HOME", fixture.Home); err != nil {
		restore()
		return nil, err
	}
	if err := os.Setenv("WAKIL_ORG", org); err != nil {
		restore()
		return nil, err
	}
	return restore, nil
}

func restoreEnv(key, value string, had bool) {
	if had {
		_ = os.Setenv(key, value)
		return
	}
	_ = os.Unsetenv(key)
}

// guardFixtureHome refuses a fixture whose home is not a real directory
// underneath its own root.
func guardFixtureHome(fixture Fixture) error {
	if fixture.Root == "" || fixture.Home == "" {
		return fmt.Errorf("seed: refusing to write with an empty fixture root or home")
	}
	// **Absolute, checked before `filepath.Abs` is allowed to hide it.** `Abs`
	// resolves a relative path against the working directory, which would make
	// a relative root and a relative home agree with each other and satisfy the
	// containment test below while pointing at neither a fixture nor the
	// operator's home — it would write beside whatever directory the runner
	// happened to start in. Measured: with this guard bypassed, a `Root: ""` run
	// wrote `e2e/driver/project/.wakil/project.json` into the repository.
	if !filepath.IsAbs(fixture.Root) || !filepath.IsAbs(fixture.Home) {
		return fmt.Errorf(
			"seed: refusing to write: fixture root %q and home %q must both be absolute, "+
				"or the production writers resolve ~/.wakil against the working directory",
			fixture.Root, fixture.Home)
	}
	// The home must exist before it can be resolved, and `Lstat` rather than
	// `Stat` so a symlink is seen as a symlink here rather than as whatever it
	// points at.
	if _, err := os.Lstat(fixture.Home); err != nil {
		return fmt.Errorf("seed: fixture home %q is unusable: %w", fixture.Home, err)
	}

	// **Resolved through `EvalSymlinks`, not compared as strings.** `Abs` is
	// lexical and `Stat` follows links, so a `<root>/home` symlinked at the
	// operator's real home satisfied containment, existence and
	// directory-ness — and wakilcore then wrote a real org into the real
	// `~/.wakil`. Both sides are resolved because macOS resolves the fixture's
	// own `/var/folders/...` root to `/private/var/folders/...`, so resolving
	// only one side would make every legitimate fixture fail containment.
	root, err := filepath.EvalSymlinks(fixture.Root)
	if err != nil {
		return fmt.Errorf("seed: fixture root %q is unusable: %w", fixture.Root, err)
	}
	home, err := filepath.EvalSymlinks(fixture.Home)
	if err != nil {
		return fmt.Errorf("seed: fixture home %q is unusable: %w", fixture.Home, err)
	}
	if root == home || !strings.HasPrefix(home, root+string(filepath.Separator)) {
		return fmt.Errorf(
			"seed: refusing to write: fixture home %q resolves to %q, which is not inside fixture "+
				"root %q — the production writers would resolve ~/.wakil somewhere this run does not own",
			fixture.Home, home, root)
	}
	info, err := os.Stat(home)
	if err != nil {
		return fmt.Errorf("seed: fixture home %q is unusable: %w", home, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("seed: fixture home %q is not a directory", home)
	}
	return nil
}

// SpareProviderFor is the spare account a launch seeds: one only when it
// carries the agent (agentBinary, the staged stub, empty otherwise). USE
// refuses an account with no claude path, and every seeded check's account
// rows and binding counts were written against the accounts it already had.
func SpareProviderFor(agentBinary string) string {
	if agentBinary == "" {
		return ""
	}
	return "e2e-provider-spare"
}

// seedSpareProvider adds the second account USE can switch to: the same agent
// binary and script as the first, under its own config dir.
func seedSpareProvider(fixture Fixture, spec SeedSpec) error {
	configDir := filepath.Join(fixture.Root, "claude-"+spec.SpareProvider)
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return fmt.Errorf("seed: making the spare account's config dir: %w", err)
	}
	if spec.AgentScript != "" {
		if err := copyFile(spec.AgentScript, filepath.Join(configDir, AgentScriptFile)); err != nil {
			return fmt.Errorf("seed: laying down the spare account's agent script: %w", err)
		}
	}
	if err := wakilcore.AddProvider(spec.Org, wakilcore.Provider{
		ID:         spec.SpareProvider,
		Kind:       wakilcore.ProviderKindClaudeCode,
		Label:      "E2E spare account",
		ConfigDir:  configDir,
		ClaudePath: spec.AgentBinary,
	}); err != nil {
		return fmt.Errorf("seed: adding provider %q: %w", spec.SpareProvider, err)
	}
	if _, err := wakilcore.LoadProviderFor(spec.Org, spec.SpareProvider); err != nil {
		return fmt.Errorf("seed: reading back provider %q: %w", spec.SpareProvider, err)
	}
	return nil
}

// seedRootlessProject writes a project that declares no roots, read back
// through the production loader.
func seedRootlessProject(root string, spec SeedSpec) (string, error) {
	dir := filepath.Join(root, spec.RootlessProject, ".wakil")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("seed: making the rootless project: %w", err)
	}
	project := wakilcore.Project{
		Name: spec.RootlessProject,
		Org:  spec.Org,
		Environments: map[string]wakilcore.Environment{
			spec.Environment: {Databases: []wakilcore.Database{}, API: []wakilcore.ApiConfig{}},
		},
	}
	encoded, err := json.MarshalIndent(project, "", "  ")
	if err != nil {
		return "", fmt.Errorf("seed: encoding the rootless project: %w", err)
	}
	file := filepath.Join(dir, "project.json")
	if err := os.WriteFile(file, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("seed: writing the rootless project: %w", err)
	}
	if _, err := wakilcore.LoadProject(file); err != nil {
		return "", fmt.Errorf("seed: the rootless project is not loadable: %w", err)
	}
	return file, nil
}
