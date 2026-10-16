package wakilcore

import (
	"encoding/json"
	"strings"
	"testing"
)

// An environment named ONE api, so a project whose backends are separate
// subdomains could reach exactly one of them. `api` is an array of named
// entries now, each with its own credential, so one backend's token never
// reaches another backend's host (#183).

func TestPickApiMirrorsPickDatabase(t *testing.T) {
	env := Environment{API: []ApiConfig{
		{Name: "api", BaseURL: "https://api.initech.dev"},
		{Name: "billing", BaseURL: "https://billing.initech.dev", AuthRef: "b"},
	}}
	got, err := PickAPI(env, "billing")
	if err != nil {
		t.Fatalf("PickAPI: %v", err)
	}
	if got.BaseURL != "https://billing.initech.dev" {
		t.Fatalf("resolved the wrong entry: %+v", got)
	}
}

func TestAnEmptyNameIsAllowedOnlyForASingleEntryEnvironment(t *testing.T) {
	one := Environment{API: []ApiConfig{{Name: "api", BaseURL: "https://a"}}}
	if _, err := PickAPI(one, ""); err != nil {
		t.Fatalf("one entry, empty name: %v", err)
	}
	two := Environment{API: []ApiConfig{{Name: "a", BaseURL: "https://a"}, {Name: "b", BaseURL: "https://b"}}}
	_, err := PickAPI(two, "")
	if err == nil || !strings.Contains(err.Error(), "name one of them") {
		t.Fatalf("an empty name with two entries must be refused, got %v", err)
	}
}

func TestAnUnknownEntryFailsLoudlyRatherThanFallingBack(t *testing.T) {
	// The whole reason this is not a "resolve to the first" helper: a
	// request that silently reached a DIFFERENT backend would carry that
	// backend's credential to a host the operator never chose.
	env := Environment{API: []ApiConfig{{Name: "api", BaseURL: "https://a"}}}
	_, err := PickAPI(env, "billing")
	if err == nil || !strings.Contains(err.Error(), "billing") {
		t.Fatalf("an unknown entry must be named in the refusal, got %v", err)
	}
}

func TestDuplicateEntryNamesAreAmbiguousRatherThanFirstWins(t *testing.T) {
	env := Environment{API: []ApiConfig{
		{Name: "billing", BaseURL: "https://one"},
		{Name: "billing", BaseURL: "https://two"},
	}}
	_, err := PickAPI(env, "billing")
	if err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("two entries sharing a name is a configuration error, got %v", err)
	}
}

func TestNoApiConfiguredIsItsOwnRefusal(t *testing.T) {
	_, err := PickAPI(Environment{}, "")
	if err == nil || !strings.Contains(err.Error(), "no api") {
		t.Fatalf("got %v", err)
	}
}

func TestAuthHeaderDefaultsToAuthorizationAndIsConfigurable(t *testing.T) {
	// An entry whose backend authenticates through a header other than
	// Authorization must be configurable, so the Keychain — not a tool
	// call — stays where the secret lives.
	plain := ApiConfig{Name: "a", BaseURL: "https://a"}
	if plain.Header() != "Authorization" {
		t.Fatalf("default header is Authorization, got %q", plain.Header())
	}
	custom := ApiConfig{Name: "a", BaseURL: "https://a", AuthHeader: "X-API-Key"}
	if custom.Header() != "X-API-Key" {
		t.Fatalf("got %q", custom.Header())
	}
}

func TestTheOldSingleObjectShapeFailsLoudlyAtLoad(t *testing.T) {
	// `"api"` KEEPS ITS KEY and becomes an array. Renaming it to "apis"
	// would make every existing object an unknown field that
	// json.Unmarshal silently ignores — an environment that reaches
	// nothing, reported as nothing wrong. Changing the type in place is
	// the loud failure, and this pins that it stays loud.
	var env Environment
	err := json.Unmarshal([]byte(`{"databases":[],"api":{"baseUrl":"https://a"}}`), &env)
	if err == nil {
		t.Fatal("an object where an array is expected must fail to decode")
	}
}

func TestAnApiArrayDecodes(t *testing.T) {
	var env Environment
	if err := json.Unmarshal([]byte(
		`{"databases":[],"api":[{"name":"billing","baseUrl":"https://b","authRef":"r","authHeader":"X-Key"}]}`,
	), &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(env.API) != 1 || env.API[0].Name != "billing" || env.API[0].AuthHeader != "X-Key" {
		t.Fatalf("decoded %+v", env.API)
	}
}

func TestNewApiListPublishesNeitherTheRefNorTheHeader(t *testing.T) {
	// Keychain entry names are no business of an agent, and neither is
	// which header carries the credential.
	list := NewApiList([]ApiConfig{
		{Name: "billing", BaseURL: "https://b", AuthRef: "wakil:initech:billing", AuthHeader: "X-Key"},
		{Name: "api", BaseURL: "https://a"},
	})
	b, err := json.Marshal(list)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	for _, leak := range []string{"wakil:initech:billing", "authRef", "X-Key", "authHeader"} {
		if strings.Contains(s, leak) {
			t.Errorf("list_apis leaked %q in %s", leak, s)
		}
	}
	if !strings.Contains(s, `"authenticated":true`) || !strings.Contains(s, `"authenticated":false`) {
		t.Errorf("authenticated is derived from the ref's presence, got %s", s)
	}
	// And the two fields it MUST publish, which greping for leaks does
	// not assert: an entry the agent cannot name or reach is not a
	// listing.
	if !strings.Contains(s, `"name":"billing"`) || !strings.Contains(s, `"baseUrl":"https://b"`) {
		t.Errorf("list_apis must publish name and baseUrl, got %s", s)
	}
}

func TestAuthHeaderThatCannotCarryACredentialIsRefusedAtResolve(t *testing.T) {
	// **The silent one.** `Host` makes req.Header.Set a no-op — net/http
	// takes the wire Host from the request URL — so the request would
	// leave UNAUTHENTICATED with no error at all, and the operator would
	// meet it as a 401 from a backend they configured a credential for.
	// Refused at PickAPI, the one gate every request passes, and before
	// the Keychain is read.
	for _, bad := range []string{"Host", "host", "Cookie", "Proxy-Authorization", "X Api Key"} {
		env := Environment{API: []ApiConfig{{Name: "a", BaseURL: "https://a", AuthHeader: bad}}}
		if _, err := PickAPI(env, ""); err == nil {
			t.Errorf("authHeader %q must be refused", bad)
		}
		if _, err := PickAPI(env, "a"); err == nil {
			t.Errorf("authHeader %q must be refused when named too", bad)
		}
	}
	// Authorization, an ordinary custom header, and an unset one all pass.
	for _, ok := range []string{"", "Authorization", "X-API-Key", "  X-API-Key  "} {
		env := Environment{API: []ApiConfig{{Name: "a", BaseURL: "https://a", AuthHeader: ok}}}
		if _, err := PickAPI(env, ""); err != nil {
			t.Errorf("authHeader %q must be allowed: %v", ok, err)
		}
	}
}

func TestHeaderReturnsTheNameItIsActuallySentUnder(t *testing.T) {
	// It returned the raw value and left three later trims to cover for
	// it. An accessor documented as "the header name this entry's
	// credential is sent in" must return the name it is sent in.
	if got := (ApiConfig{AuthHeader: "  X-API-Key  "}).Header(); got != "X-API-Key" {
		t.Errorf("Header() must trim, got %q", got)
	}
	if got := (ApiConfig{}).Header(); got != "Authorization" {
		t.Errorf("the default lives in ResolveAuthHeader, got %q", got)
	}
	if got := ResolveAuthHeader("   "); got != "Authorization" {
		t.Errorf("whitespace-only is unset, got %q", got)
	}
}

func TestNewApiListIsNeverNil(t *testing.T) {
	b, err := json.Marshal(NewApiList(nil))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(b) != `{"apis":[]}` {
		t.Fatalf("an environment with no entries marshals as %s", b)
	}
}
