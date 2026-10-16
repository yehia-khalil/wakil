package wakilcore

import "testing"

func locateProject() Project {
	return Project{Environments: map[string]Environment{
		"staging": {API: []ApiConfig{
			{Name: "billing", BaseURL: "https://billing.example.com"},
			{Name: "catalog", BaseURL: "https://api.example.com"},
			{Name: "catalog-v2", BaseURL: "https://api.example.com/v2/"},
		}},
		"qa": {API: []ApiConfig{{Name: "catalog", BaseURL: "https://catalog-qa.example.com"}}},
	}}
}

func TestLocateAPIURLInTheActiveEnvironment(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://billing.example.com/v1/invoices?paid=true")
	if !got.Found || !got.Active || got.Entry != "billing" || got.Environment != "staging" ||
		got.Path != "/v1/invoices?paid=true" {
		t.Fatalf("%+v", got)
	}
}

// Review Focus 2.
func TestLocateAPIURLLongestBasePathWins(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://api.example.com/v2/items/7")
	if got.Entry != "catalog-v2" || got.Path != "/items/7" {
		t.Fatalf("%+v", got)
	}
	got = LocateAPIURL(locateProject(), "staging", "https://api.example.com/v20/items")
	if got.Entry != "catalog" || got.Path != "/v20/items" {
		t.Fatalf("a base path must match whole segments: %+v", got)
	}
	got = LocateAPIURL(locateProject(), "staging", "https://api.example.com/v2")
	if got.Entry != "catalog-v2" || got.Path != "" {
		t.Fatalf("the base itself: %+v", got)
	}
}

// Review Focus 3.
func TestLocateAPIURLNormalizesHostAndDefaultPort(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://BILLING.example.com:443/x")
	if got.Entry != "billing" || got.Path != "/x" {
		t.Fatalf("%+v", got)
	}
	if got := LocateAPIURL(locateProject(), "staging", "http://billing.example.com/x"); got.Found {
		t.Fatalf("another scheme is another origin: %+v", got)
	}
	if got := LocateAPIURL(locateProject(), "staging", "https://billing.example.com:8443/x"); got.Found {
		t.Fatalf("another port is another origin: %+v", got)
	}
}

func TestLocateAPIURLInAnotherEnvironment(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://catalog-qa.example.com/x")
	if !got.Found || got.Active || got.Environment != "qa" || got.Entry != "catalog" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLNowhere(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://other.example.net/x")
	if got.Found || got.Host != "other.example.net" || got.Environment != "staging" {
		t.Fatalf("%+v", got)
	}
	want := []string{"billing", "catalog", "catalog-v2"}
	if len(got.Entries) != 3 || got.Entries[0] != want[0] || got.Entries[2] != want[2] {
		t.Fatalf("entries %v, want %v", got.Entries, want)
	}
}

func TestLocateAPIURLWithNoHostSaysSoAndStillListsTheEntries(t *testing.T) {
	for _, raw := range []string{"api.example.com/v1/a", "/v1/a", "http://[::1"} {
		got := LocateAPIURL(locateProject(), "staging", raw)
		if got.Found || !got.NoHost {
			t.Errorf("%q: %+v", raw, got)
		}
		if len(got.Entries) != 3 {
			t.Errorf("%q: entries %v", raw, got.Entries)
		}
	}
	if got := LocateAPIURL(locateProject(), "staging", "https://other.example.net/x"); got.NoHost {
		t.Errorf("a URL with a host is NoHost: %+v", got)
	}
}

func wwwProject(extra ...ApiConfig) Project {
	api := append([]ApiConfig{
		{Name: "billing", BaseURL: "https://billing.example.com"},
		{Name: "shop", BaseURL: "https://www.shop.example.com"},
	}, extra...)
	return Project{Environments: map[string]Environment{
		"staging": {API: api},
		"qa":      {API: []ApiConfig{{Name: "catalog", BaseURL: "https://catalog-qa.example.com"}}},
	}}
}

func TestLocateAPIURLWwwHostMatchesBareEntry(t *testing.T) {
	got := LocateAPIURL(wwwProject(), "staging", "https://www.billing.example.com/v1/x")
	if !got.Found || got.Entry != "billing" || got.Path != "/v1/x" ||
		got.PastedHost != "www.billing.example.com" || got.EntryHost != "billing.example.com" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLBareHostMatchesWwwEntry(t *testing.T) {
	got := LocateAPIURL(wwwProject(), "staging", "https://shop.example.com/a")
	if !got.Found || got.Entry != "shop" || got.PastedHost != "shop.example.com" || got.EntryHost != "www.shop.example.com" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLExactHostBeatsWwwEquivalent(t *testing.T) {
	p := wwwProject(ApiConfig{Name: "billing-www", BaseURL: "https://www.billing.example.com"})
	got := LocateAPIURL(p, "staging", "https://www.billing.example.com/x")
	if got.Entry != "billing-www" || got.PastedHost != "" || got.EntryHost != "" {
		t.Fatalf("%+v", got)
	}
	got = LocateAPIURL(p, "staging", "https://billing.example.com/x")
	if got.Entry != "billing" || got.PastedHost != "" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLOnlyWwwIsForgiven(t *testing.T) {
	for _, u := range []string{
		"https://api.billing.example.com/x", "https://wwwbilling.example.com/x",
		"https://www.www.billing.example.com/x", "http://www.billing.example.com/x",
		"https://www.billing.example.com:8443/x",
	} {
		if got := LocateAPIURL(wwwProject(), "staging", u); got.Found {
			t.Fatalf("%s: %+v", u, got)
		}
	}
}

func TestLocateAPIURLWwwRuleInOtherEnvironments(t *testing.T) {
	got := LocateAPIURL(wwwProject(), "qa", "https://WWW.billing.example.com/x")
	if !got.Found || got.Active || got.Environment != "staging" || got.Entry != "billing" ||
		got.PastedHost != "WWW.billing.example.com" || got.EntryHost != "billing.example.com" {
		t.Fatalf("%+v", got)
	}
}

func envsProject(dev, stage string) Project {
	return Project{Environments: map[string]Environment{
		"dev":   {API: []ApiConfig{{Name: "billing", BaseURL: dev}}},
		"stage": {API: []ApiConfig{{Name: "exact", BaseURL: stage}}},
	}}
}

func TestLocateAPIURLExactInAnotherEnvironmentBeatsWwwInTheActiveOne(t *testing.T) {
	p := envsProject("https://billing.x.com", "https://www.billing.x.com")
	got := LocateAPIURL(p, "dev", "https://www.billing.x.com/v1")
	if !got.Found || got.Active || got.Environment != "stage" || got.Entry != "exact" ||
		got.PastedHost != "" || got.EntryHost != "" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLWwwInTheActiveEnvironmentFillsWhenNoneHasTheExactHost(t *testing.T) {
	p := envsProject("https://billing.x.com", "https://other.x.com")
	got := LocateAPIURL(p, "dev", "https://www.billing.x.com/v1")
	if !got.Active || got.Entry != "billing" || got.PastedHost != "www.billing.x.com" || got.EntryHost != "billing.x.com" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLExactInTheActiveEnvironmentBeatsEverything(t *testing.T) {
	p := envsProject("https://www.billing.x.com", "https://www.billing.x.com")
	got := LocateAPIURL(p, "dev", "https://www.billing.x.com/v1")
	if !got.Active || got.Entry != "billing" || got.PastedHost != "" {
		t.Fatalf("%+v", got)
	}
}
