package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// writeProjectFixture writes a project.json and registers it under org.
func writeProjectFixture(t *testing.T, org, name string, p Project) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "project.json")
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		t.Fatal(err)
	}
	if reg == nil {
		reg = map[string]ProjectEntry{}
	}
	reg[name] = ProjectEntry{Path: path}
	if err := SaveRegistry(org, reg); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestConfigTreeIsFourDeepAndProvidersSitBesideTheProjects pins the two
// shapes the settings pane's layout is built on, both of them binding
// (#198). An ENVIRONMENT holds the databases and the API — not a project —
// so the tree is four levels, and a provider binding is (org, id) with
// nowhere to nest, so providers sit beside the projects rather than under
// one.
func TestConfigTreeIsFourDeepAndProvidersSitBesideTheProjects(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{DisplayName: "Acme", JiraBase: "https://acme.atlassian.net"}); err != nil {
		t.Fatal(err)
	}
	configDir := filepath.Join(t.TempDir(), ".claude-main")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, Label: "Main", ConfigDir: configDir,
	}); err != nil {
		t.Fatal(err)
	}
	writeProjectFixture(t, "acme", "orders", Project{
		Name:  "orders",
		Org:   "acme",
		Roots: []Root{{Path: "/src/orders", Role: "service"}},
		Environments: map[string]Environment{
			"staging": {
				Databases: []Database{
					{Name: "core", Driver: "mysql", Ref: "db:orders-core"},
					{Name: "events", Driver: "mongo", Ref: "db:orders-events", WriteRef: "db:orders-events-rw"},
				},
				API: []ApiConfig{{Name: "core", BaseURL: "https://api.staging.acme.test", AuthRef: "api:staging"}},
			},
			"production": {},
		},
	})

	tree, err := LoadConfigTree()
	if err != nil {
		t.Fatal(err)
	}

	if tree.Org.ID != "acme" || tree.Org.DisplayName != "Acme" {
		t.Fatalf("org = %+v", tree.Org)
	}
	if tree.Org.JiraBase != "https://acme.atlassian.net" {
		t.Errorf("JiraBase = %q", tree.Org.JiraBase)
	}

	// Providers are org-level. One entry, and it is not reachable through
	// any project.
	if len(tree.Providers) != 1 || tree.Providers[0].ID != "main" {
		t.Fatalf("providers = %+v", tree.Providers)
	}
	if tree.Providers[0].Kind != ProviderKindClaudeCode {
		t.Errorf("kind = %q", tree.Providers[0].Kind)
	}

	if len(tree.Projects) != 1 {
		t.Fatalf("projects = %+v", tree.Projects)
	}
	project := tree.Projects[0]
	if project.Name != "orders" {
		t.Fatalf("project name = %q", project.Name)
	}
	if len(project.Roots) != 1 || project.Roots[0].Path != "/src/orders" {
		t.Errorf("roots = %+v", project.Roots)
	}

	// Environments sorted by name, so the tree draws in a stable order
	// rather than Go's randomised map order.
	if len(project.Environments) != 2 {
		t.Fatalf("environments = %+v", project.Environments)
	}
	if project.Environments[0].Name != "production" || project.Environments[1].Name != "staging" {
		t.Fatalf("environments are not sorted by name: %+v", project.Environments)
	}

	staging := project.Environments[1]
	if len(staging.Databases) != 2 {
		t.Fatalf("databases = %+v", staging.Databases)
	}
	// A LIST since 2c-iv: one request runs against staging and then
	// production, so an entry carries a name.
	if len(staging.API) != 1 || staging.API[0].BaseURL != "https://api.staging.acme.test" {
		t.Fatalf("api = %+v", staging.API)
	}

	// The environment with nothing in it still draws, with both its nodes
	// empty. An absent environment and an empty one are different facts.
	production := project.Environments[0]
	if production.Databases == nil {
		t.Error("an environment with no databases must report [], not null")
	}
	// `[]`, not null, for `Databases`' reason one assertion up: an
	// environment that declares no API entries and one that could not be
	// read are different facts and must not share a representation.
	if production.API == nil {
		t.Error("an environment with no API entries must report [], not null")
	}
	if len(production.API) != 0 {
		t.Errorf("api = %+v; want empty for an environment that declares none", production.API)
	}
}

// TestConfigTreeReportsPresenceAndNeverAValue is the standing rule applied
// to the one read this ticket ships: a credential row carries its
// reference and whether it is present, and there is no field on any of
// these types that could hold a secret's value.
func TestConfigTreeReportsPresenceAndNeverAValue(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	writeProjectFixture(t, "acme", "orders", Project{
		Name: "orders", Org: "acme",
		Environments: map[string]Environment{
			"staging": {Databases: []Database{
				{Name: "core", Driver: "mysql", Ref: "db:core"},
				{Name: "ledger", Driver: "mysql", Ref: "db:ledger", WriteRef: "db:ledger-rw"},
			}},
		},
	})

	tree, err := LoadConfigTree()
	if err != nil {
		t.Fatal(err)
	}
	databases := tree.Projects[0].Environments[0].Databases

	// The ref is a Keychain ENTRY NAME and is shown; the value is never
	// read, so there is nowhere for one to travel.
	if databases[0].Ref != "db:core" {
		t.Errorf("ref = %q", databases[0].Ref)
	}
	// Writable is derived from WriteRef rather than stored, exactly as
	// DatabaseInfo derives it, so the two cannot disagree.
	if databases[0].Writable {
		t.Error("a database with no writeRef is not writable")
	}
	if !databases[1].Writable || databases[1].WriteRef != "db:ledger-rw" {
		t.Errorf("ledger = %+v", databases[1])
	}

	// The whole tree, marshalled, must contain no key that could hold a
	// secret. This is checked on the encoded form rather than the struct
	// because the wire is what leaves the process.
	b, err := json.Marshal(tree)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{`"dsn"`, `"secret"`, `"token"`, `"password"`, `"value"`} {
		if containsKey(string(b), forbidden) {
			t.Errorf("the config tree publishes %s", forbidden)
		}
	}
}

func containsKey(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

// TestConfigTreeNamesWhatItCouldNotRead carries the house partiality rule:
// an unreadable or misfiled project is REPORTED, never silently dropped.
// The pane draws what it was told, and "could not look" must not render as
// "there is nothing there".
func TestConfigTreeNamesWhatItCouldNotRead(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := CreateOrg("other", Org{}); err != nil {
		t.Fatal(err)
	}
	writeProjectFixture(t, "acme", "good", Project{Name: "good", Org: "acme"})
	writeProjectFixture(t, "acme", "elsewhere", Project{Name: "elsewhere", Org: "other"})

	reg, err := LoadRegistryFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	reg["gone"] = ProjectEntry{Path: filepath.Join(t.TempDir(), "does-not-exist.json")}
	if err := SaveRegistry("acme", reg); err != nil {
		t.Fatal(err)
	}

	tree, err := LoadConfigTree()
	if err != nil {
		t.Fatal(err)
	}
	if len(tree.Projects) != 1 || tree.Projects[0].Name != "good" {
		t.Fatalf("projects = %+v", tree.Projects)
	}
	if len(tree.Misfiled) != 1 || tree.Misfiled[0].Name != "elsewhere" {
		t.Errorf("misfiled = %+v", tree.Misfiled)
	}
	if len(tree.Unreadable) != 1 || tree.Unreadable[0] != "gone" {
		t.Errorf("unreadable = %+v", tree.Unreadable)
	}
}

// TestConfigTreeProjectsAreSortedByName — the pane draws this list top to
// bottom and a registry is a map, so without a sort the tree reorders
// itself between two reads of an unchanged disk.
func TestConfigTreeProjectsAreSortedByName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"zebra", "alpha", "mango"} {
		writeProjectFixture(t, "acme", name, Project{Name: name, Org: "acme"})
	}
	tree, err := LoadConfigTree()
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, p := range tree.Projects {
		got = append(got, p.Name)
	}
	want := []string{"alpha", "mango", "zebra"}
	for i := range want {
		if i >= len(got) || got[i] != want[i] {
			t.Fatalf("projects = %v; want %v", got, want)
		}
	}
}

// TestConfigTreeAnswersForAnOrgWithNothingInIt. A freshly created org has
// no projects and no providers, and the pane must still draw its three
// nodes rather than fail. Empty slices, never nil, so the wire carries []
// and not null.
func TestConfigTreeAnswersForAnOrgWithNothingInIt(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "empty")
	if err := CreateOrg("empty", Org{}); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTree()
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.ID != "empty" {
		t.Fatalf("org = %+v", tree.Org)
	}
	if tree.Projects == nil || tree.Providers == nil {
		t.Fatalf("projects and providers must be [] rather than null: %+v", tree)
	}
	b, err := json.Marshal(tree)
	if err != nil {
		t.Fatal(err)
	}
	if containsKey(string(b), `"projects":null`) || containsKey(string(b), `"providers":null`) {
		t.Errorf("tree marshalled with nulls: %s", b)
	}
}

func TestConfigTreeCarriesSpeechProvider(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{SpeechProvider: "apple"}); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.SpeechProvider != "apple" {
		t.Errorf("tree.Org.SpeechProvider = %q", tree.Org.SpeechProvider)
	}
}

func TestConfigTreeCarriesTheEditorTiers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	pdir := t.TempDir()
	pp := filepath.Join(pdir, "project.json")
	raw := `{"name":"widgets","org":"acme","roots":[{"path":"."}],"environments":{},"editor":{"tabSize":2,"insertSpaces":false}}`
	if err := os.WriteFile(pp, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("acme", map[string]ProjectEntry{"widgets": {Path: pp}}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{FontSize: intp(15)}); err != nil {
		t.Fatal(err)
	}

	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Editor != (EditorAppValues{FontSize: 15, WordWrap: false, Autosave: AutosaveOff, ShowIgnored: true, GhostText: true, InlineBlame: true}) {
		t.Errorf("tree.Editor = %+v", tree.Editor)
	}
	if tree.EditorError != "" {
		t.Errorf("tree.EditorError = %q", tree.EditorError)
	}
	if len(tree.Projects) != 1 || !reflect.DeepEqual(tree.Projects[0].Editor, EditorProjectValues{TabSize: 2, InsertSpaces: false, HeavyFolders: []string{"vendor", "node_modules"}}) {
		t.Errorf("tree.Projects = %+v", tree.Projects)
	}
}

// Review Focus 2: the tree still answers, with the defaults and the error, when settings.json
// does not parse.
func TestConfigTreeNamesAMalformedSettingsFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	path := appSettingsFile(t)
	if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.EditorError == "" || tree.Editor.FontSize != DefaultEditorFontSize {
		t.Errorf("tree = %+v; want defaults plus editorError", tree)
	}
}

func TestConfigTreeCarriesTheBrowserSettings(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Browser != (BrowserSettings{SearchEngine: "google"}) {
		t.Errorf("default tree.Browser = %+v", tree.Browser)
	}
	if err := WriteBrowserSettings(BrowserSettingsPatch{SearchEngine: strp("bing"), StartPage: strp("https://example.com")}); err != nil {
		t.Fatal(err)
	}
	if tree, err = LoadConfigTreeFor("acme"); err != nil {
		t.Fatal(err)
	}
	if tree.Browser != (BrowserSettings{SearchEngine: "bing", StartPage: "https://example.com"}) {
		t.Errorf("tree.Browser = %+v", tree.Browser)
	}
}

func TestConfigTreeCarriesTheOrgGitIdentity(t *testing.T) {
	localOrg(t)
	name, email := "Org Person", "org@example.test"
	if err := UpdateOrg("initech", OrgPatch{GitName: &name, GitEmail: &email}); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.GitName != name || tree.Org.GitEmail != email {
		t.Fatalf("%+v", tree.Org)
	}
}

// TestConfigTreeEnvironmentsCarryProduction pins that the tree states which
// environments are production from EnvironmentIsProduction — the explicit flag
// wins, the name `production` is production when no flag is set — never the
// raw *bool, so the agent's per-site price cannot drift from the rest.
func TestConfigTreeEnvironmentsCarryProduction(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	writeProjectFixture(t, "acme", "orders", Project{
		Name: "orders",
		Org:  "acme",
		Environments: map[string]Environment{
			"live":       {Production: boolp(true)},
			"production": {},
			"prod":       {},
			"unflagged":  {Production: boolp(false)},
		},
	})
	writeProjectFixture(t, "acme", "billing", Project{
		Name: "billing",
		Org:  "acme",
		Environments: map[string]Environment{
			"production": {Production: boolp(false)},
		},
	})

	tree, err := LoadConfigTree()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, p := range tree.Projects {
		for _, e := range p.Environments {
			got[p.Name+"/"+e.Name] = e.Production
		}
	}
	want := map[string]bool{
		"orders/live": true, "orders/production": true, "orders/prod": false, "orders/unflagged": false,
		"billing/production": false,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("production flags = %v, want %v", got, want)
	}
	b, err := json.Marshal(tree.Projects[0].Environments[0])
	if err != nil || !json.Valid(b) || !strings.Contains(string(b), `"production":`) {
		t.Fatalf("wire form lacks production: %s (%v)", b, err)
	}
}
