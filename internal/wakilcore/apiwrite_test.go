package wakilcore

import (
	"os"
	"strings"
	"testing"
)

// apiSetup points HOME and the org at a throwaway acme, with a fake Keychain,
// and files one project whose staging environment holds `api`.
func apiSetup(t *testing.T, api string) string {
	t.Helper()
	fakeKeychain(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	return projectFixture(t, "acme", `{"name":"shop","org":"acme","environments":{"staging":{"databases":[],"api":`+api+`}}}`)
}

func apiEntries(t *testing.T, path string) []ApiConfig {
	t.Helper()
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	return p.Environments["staging"].API
}

func TestSetApiEntryStoresTheTokenInTheKeychainNotTheFile(t *testing.T) {
	path := apiSetup(t, `[]`)
	if err := SetApiEntry(ApiEntryRequest{
		ProjectPath: path, Environment: "staging", Name: "orders-api",
		BaseURL: "https://api.example.com/", Token: "Bearer s3cret",
	}); err != nil {
		t.Fatal(err)
	}
	api := apiEntries(t, path)
	if len(api) != 1 || api[0].AuthRef != "api:shop:staging:orders-api" {
		t.Fatalf("api = %+v", api)
	}
	if api[0].BaseURL != "https://api.example.com" {
		t.Errorf("baseUrl = %q", api[0].BaseURL)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "s3cret") {
		t.Error("the token reached the project file")
	}
	got, err := SecretGetFor("acme", api[0].AuthRef)
	if err != nil || got != "Bearer s3cret" {
		t.Errorf("keychain = %q, %v", got, err)
	}
}

func TestSetApiEntryWithoutATokenKeepsAuthRef(t *testing.T) {
	path := apiSetup(t, `[{"name":"orders-api","baseUrl":"https://old.example.com","authRef":"legacy-token"}]`)
	if err := SetApiEntry(ApiEntryRequest{
		ProjectPath: path, Environment: "staging", Name: "orders-api",
		BaseURL: "https://new.example.com",
	}); err != nil {
		t.Fatal(err)
	}
	api := apiEntries(t, path)
	if len(api) != 1 || api[0].AuthRef != "legacy-token" || api[0].BaseURL != "https://new.example.com" {
		t.Errorf("api = %+v", api)
	}
	if p, _ := SecretPresenceFor("acme", "api:shop:staging:orders-api"); p.Present {
		t.Error("a Keychain item was written without a token")
	}
}

func TestSetApiEntryRefusesAndWritesNothing(t *testing.T) {
	cases := []struct{ name, base, header, entry string }{
		{"http", "http://x", "", "orders-api"},
		{"credentials", "https://u:p@x", "", "orders-api"},
		{"query", "https://x/?q=1", "", "orders-api"},
		{"host header", "https://x", "Host", "orders-api"},
		{"empty name", "https://x", "", ""},
		{"slash name", "https://x", "", "a/b"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := apiSetup(t, `[]`)
			before, _ := os.ReadFile(path)
			err := SetApiEntry(ApiEntryRequest{
				ProjectPath: path, Environment: "staging", Name: c.entry,
				BaseURL: c.base, AuthHeader: c.header, Token: "Bearer s3cret",
			})
			if err == nil {
				t.Fatal("refusal expected")
			}
			after, _ := os.ReadFile(path)
			if string(before) != string(after) {
				t.Error("the file changed on a refusal")
			}
			if p, _ := SecretPresenceFor("acme", ApiRef("shop", "staging", c.entry)); p.Present {
				t.Error("a Keychain item was written on a refusal")
			}
		})
	}
}

func TestUpdateApiEntryEditsOnlyWhatIsSet(t *testing.T) {
	path := apiSetup(t, `[
	  {"name":"orders-api","baseUrl":"https://a.example.com","authRef":"legacy-token","authHeader":"X-Key"},
	  {"name":"billing","baseUrl":"https://b.example.com"}]`)
	str := func(s string) *string { return &s }

	if err := UpdateApiEntry(path, "staging", "orders-api", ApiEntryEdit{NewName: str("orders")}); err != nil {
		t.Fatal(err)
	}
	e := apiEntries(t, path)[0]
	if e.Name != "orders" || e.BaseURL != "https://a.example.com" || e.AuthHeader != "X-Key" || e.AuthRef != "legacy-token" {
		t.Errorf("entry = %+v", e)
	}

	err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{NewName: str("billing")})
	if err == nil || !strings.Contains(err.Error(), "billing") {
		t.Errorf("clash refusal = %v", err)
	}
	if err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{NewName: str("orders")}); err != nil {
		t.Errorf("rename to its own name: %v", err)
	}
	if err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{BaseURL: str("http://x")}); err == nil {
		t.Error("an http baseUrl was accepted")
	}
	if err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{AuthHeader: str("Host")}); err == nil {
		t.Error("a Host authHeader was accepted")
	}
	if err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{NewName: str("a/b")}); err == nil {
		t.Error("a slash name was accepted")
	}
	if err := UpdateApiEntry(path, "staging", "nope", ApiEntryEdit{}); err == nil ||
		!strings.Contains(err.Error(), `no API entry "nope" in environment "staging"`) {
		t.Errorf("missing entry = %v", err)
	}
	if err := UpdateApiEntry(path, "prod", "orders", ApiEntryEdit{}); err == nil ||
		!strings.Contains(err.Error(), `no environment "prod" in project "shop"`) {
		t.Errorf("missing environment = %v", err)
	}
	if err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{BaseURL: str("https://c.example.com/")}); err != nil {
		t.Fatal(err)
	}
	if got := apiEntries(t, path)[0].BaseURL; got != "https://c.example.com" {
		t.Errorf("baseUrl = %q", got)
	}

	if err := SecretSetFor("acme", "legacy-token", "Bearer x"); err != nil {
		t.Fatal(err)
	}
	if err := UpdateApiEntry(path, "staging", "orders", ApiEntryEdit{ClearToken: true}); err != nil {
		t.Fatal(err)
	}
	if apiEntries(t, path)[0].AuthRef != "" {
		t.Error("ClearToken kept the authRef")
	}
	if got, err := SecretGetFor("acme", "legacy-token"); err != nil || got != "Bearer x" {
		t.Errorf("the Keychain item did not survive: %q, %v", got, err)
	}
}

func TestRemoveApiEntryKeepsTheKeychainItem(t *testing.T) {
	path := apiSetup(t, `[]`)
	if err := SetApiEntry(ApiEntryRequest{
		ProjectPath: path, Environment: "staging", Name: "orders-api",
		BaseURL: "https://api.example.com", Token: "Bearer s3cret",
	}); err != nil {
		t.Fatal(err)
	}
	if err := RemoveApiEntry(path, "staging", "orders-api"); err != nil {
		t.Fatal(err)
	}
	if len(apiEntries(t, path)) != 0 {
		t.Error("the entry was not removed")
	}
	if p, _ := SecretPresenceFor("acme", ApiRef("shop", "staging", "orders-api")); !p.Present {
		t.Error("removing an entry deleted its Keychain item")
	}
	if err := RemoveApiEntry(path, "staging", "orders-api"); err == nil ||
		!strings.Contains(err.Error(), `no API entry "orders-api" in environment "staging"`) {
		t.Errorf("second removal = %v", err)
	}
}

func TestApiWritesRefuseAnotherOrganisationsProject(t *testing.T) {
	apiSetup(t, `[]`)
	if err := CreateOrg("other", Org{}); err != nil {
		t.Fatal(err)
	}
	path := projectFixture(t, "other",
		`{"name":"elsewhere","org":"other","environments":{"staging":{"api":[{"name":"x","baseUrl":"https://x.example.com"}]}}}`)
	str := "y"
	errs := []error{
		SetApiEntry(ApiEntryRequest{ProjectPath: path, Environment: "staging", Name: "x", BaseURL: "https://x.example.com", Token: "t"}),
		UpdateApiEntry(path, "staging", "x", ApiEntryEdit{NewName: &str}),
		RemoveApiEntry(path, "staging", "x"),
	}
	for i, err := range errs {
		if err == nil || !strings.Contains(err.Error(), "read-only here") {
			t.Errorf("write %d: %v", i, err)
		}
	}
	if p, _ := SecretPresenceFor("acme", ApiRef("elsewhere", "staging", "x")); p.Present {
		t.Error("a Keychain item was written for another org's project")
	}
}
