package wakilcore

import (
	"encoding/json"
	"testing"
)

func boolp(b bool) *bool { return &b }

// Production was a name comparison, so an environment spelled `prod`
// silently lost both the red room and the typed confirmation, and one
// named `production` that is not one could not say so (Decision 26, #182).
// It is now DECLARED, and the name supplies only the default.

func TestADeclaredProductionIsProductionWhateverItIsNamed(t *testing.T) {
	for _, name := range []string{"prod", "live", "blue", "staging"} {
		if !EnvironmentIsProduction(name, Environment{Production: boolp(true)}) {
			t.Errorf("%q declaring production:true must be production", name)
		}
	}
}

func TestADisarmedProductionIsHonoured(t *testing.T) {
	// The flag is authoritative in BOTH directions: a deliberate disarm
	// replaces an accidental one. An environment named `production` that
	// declares false is a scratch copy somebody made, and saying so in
	// configuration must beat the spelling.
	if EnvironmentIsProduction("production", Environment{Production: boolp(false)}) {
		t.Fatal("production:false on an environment named production must be honoured")
	}
}

func TestAbsentFallsBackToTheNameExactlyAsBefore(t *testing.T) {
	// Wakil never materialises the default. "Absent means not production"
	// would stop every shipped project's production environment being
	// production on one release.
	if !EnvironmentIsProduction("production", Environment{}) {
		t.Fatal("an undeclared environment named production is production")
	}
	// The name match is unchanged, and deliberately narrow: widening it
	// stays refused, because with most actions declaring no price, adding
	// `prod` to the set converts a `prod` database mutation from .gate to
	// .block and costs the operator the write entirely.
	for _, name := range []string{"prod", "prd", "live", "preprod", "staging"} {
		if EnvironmentIsProduction(name, Environment{}) {
			t.Errorf("%q with no flag must not be production by name", name)
		}
	}
	// Trimmed and case-folded, as the Swift side has been since 2026-09-14.
	for _, name := range []string{" production", "Production", "PRODUCTION\n"} {
		if !EnvironmentIsProduction(name, Environment{}) {
			t.Errorf("%q must match", name)
		}
	}
}

func TestASuspiciousNameWithNoFlagIsSurfaced(t *testing.T) {
	for _, name := range []string{"prod", "prd", "live", "preprod", "PROD"} {
		if EnvironmentNamingNotice(name, Environment{}) == "" {
			t.Errorf("%q with no flag must be surfaced", name)
		}
	}
	// Declaring either way answers the question, so there is nothing left
	// for a reader to misread and nothing to say.
	for _, b := range []*bool{boolp(true), boolp(false)} {
		if n := EnvironmentNamingNotice("prod", Environment{Production: b}); n != "" {
			t.Errorf("a declared prod needs no notice, got %q", n)
		}
	}
}

func TestADisarmedProductionIsSurfacedToo(t *testing.T) {
	// The other direction a reader would misread: the name says production
	// and the behaviour is not.
	if EnvironmentNamingNotice("production", Environment{Production: boolp(false)}) == "" {
		t.Fatal("a production declaring false must be surfaced")
	}
	if n := EnvironmentNamingNotice("production", Environment{Production: boolp(true)}); n != "" {
		t.Fatalf("a production declaring true is not surprising, got %q", n)
	}
	if n := EnvironmentNamingNotice("staging", Environment{}); n != "" {
		t.Fatalf("an ordinary environment needs no notice, got %q", n)
	}
}

func TestTheProductionFlagRoundTripsAndAbsenceIsNotFalse(t *testing.T) {
	// A pointer in Go because absent is not false, and `omitempty` so an
	// environment that never declared one does not grow the field.
	var env Environment
	if err := json.Unmarshal([]byte(`{"databases":[],"production":false}`), &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if env.Production == nil || *env.Production {
		t.Fatalf("production:false must decode as a non-nil false, got %v", env.Production)
	}
	var undeclared Environment
	if err := json.Unmarshal([]byte(`{"databases":[]}`), &undeclared); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if undeclared.Production != nil {
		t.Fatal("an absent flag must decode as nil, not false")
	}
}

// ---------------------------------------------------------------------
// EnvironmentIsReadOnly. Moved here from cmd/wakil-ctx with the function
// itself: the rule is read off an Environment and nothing about it is
// specific to the tool that serves it, so it belongs beside
// EnvironmentIsProduction — the other half of what list_environments
// publishes per environment.

// The three tests below pinned EnvironmentIsReadOnly to Database.ReadOnly
// until 2026-09-10. They now pin it to WriteRef, and the rewrite is the
// point rather than an incidental churn: the old rule reported a safety
// fact derived from a field that granted and protected nothing, so it
// could be — and, for a database carrying both readOnly:true and a
// writeRef, WAS — wrong in the dangerous direction. See issue #14.

func TestEnvironmentReadOnlyWhenNoDatabaseHasAWriteRef(t *testing.T) {
	env := Environment{
		Databases: []Database{
			{Name: "a"},
			{Name: "b"},
		},
	}
	if !EnvironmentIsReadOnly(env) {
		t.Fatal("expected environment where no database has a writeRef to report true")
	}
}

func TestEnvironmentReadOnlyMixed(t *testing.T) {
	env := Environment{
		Databases: []Database{
			{Name: "a"},
			{Name: "b", WriteRef: "db:b:write"},
		},
	}
	if EnvironmentIsReadOnly(env) {
		t.Fatal("expected environment with a writable database to report false, not true")
	}
}

func TestEnvironmentReadOnlyNoDatabases(t *testing.T) {
	env := Environment{Databases: nil}
	if !EnvironmentIsReadOnly(env) {
		t.Fatal("expected environment with no databases to vacuously report true")
	}
}

// #182 widened EnvironmentIsReadOnly. It looped over databases only, so an
// environment whose API is configured — the one surface in the product that
// can change somebody else's system — reported read-only.

func TestEnvironmentWithAnApiIsNotReadOnly(t *testing.T) {
	env := Environment{
		Databases: []Database{{Name: "a"}},
		API:       []ApiConfig{{Name: "billing", BaseURL: "https://billing.initech.dev"}},
	}
	if EnvironmentIsReadOnly(env) {
		t.Fatal("an environment with a configured API can be written to through it")
	}
}

func TestEnvironmentWithNeitherIsStillVacuouslyReadOnly(t *testing.T) {
	if !EnvironmentIsReadOnly(Environment{}) {
		t.Fatal("an environment declaring nothing reports true vacuously")
	}
}
