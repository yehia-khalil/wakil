package wakilcore

import (
	"reflect"
	"strings"
	"testing"
)

func localOrg(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
}

func TestSetLocalProviderWritesURLAndDefaultServes(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: " http://127.0.0.1:8012/ "}); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProviderFor("initech", "qwen")
	if err != nil {
		t.Fatal(err)
	}
	if p.Kind != ProviderKindLocal || p.BaseURL != "http://127.0.0.1:8012" {
		t.Errorf("got kind %q baseURL %q", p.Kind, p.BaseURL)
	}
	if !reflect.DeepEqual(p.Serves, []string{QuickOpInfill}) {
		t.Errorf("serves = %v, want [infill]", p.Serves)
	}
}

func TestSetLocalProviderOverridesItsOwnRecord(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	if err := SetLocalProvider("initech", Provider{ID: "qwen", Label: "Qwen", BaseURL: "http://localhost:9000",
		Serves: []string{QuickOpRespond, QuickOpInfill, QuickOpInfill}}); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadProviderFor("initech", "qwen")
	if p.BaseURL != "http://localhost:9000" || p.Label != "Qwen" ||
		!reflect.DeepEqual(p.Serves, []string{QuickOpInfill, QuickOpRespond}) {
		t.Errorf("got %+v", p)
	}
}

func TestSetLocalProviderRefusesBadURLUnknownOpAndOtherKinds(t *testing.T) {
	localOrg(t)
	for _, tc := range []struct {
		p    Provider
		want string
	}{
		{Provider{ID: "a", BaseURL: "ftp://x"}, "baseURL"},
		{Provider{ID: "a", BaseURL: ""}, "baseURL"},
		{Provider{ID: "a", BaseURL: "http://x", Serves: []string{"chat"}}, "serves"},
	} {
		if err := SetLocalProvider("initech", tc.p); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%+v: got %v, want an error naming %q", tc.p, err, tc.want)
		}
	}
	if err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex}); err != nil {
		t.Fatal(err)
	}
	if err := SetLocalProvider("initech", Provider{ID: "cx", BaseURL: "http://x"}); err == nil {
		t.Error("SetLocalProvider overwrote a codex record")
	}
}

func TestAddProviderRefusesBaseURLOnOtherKinds(t *testing.T) {
	localOrg(t)
	err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex, BaseURL: "http://x"})
	if err == nil || !strings.Contains(err.Error(), "only to --kind local") {
		t.Errorf("got %v", err)
	}
}

func TestConfigTreeResolvesServes(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex}); err != nil {
		t.Fatal(err)
	}
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string][]string{}
	for _, p := range tree.Providers {
		got[p.ID] = p.Serves
	}
	if !reflect.DeepEqual(got["qwen"], []string{"infill"}) || len(got["cx"]) != 0 || got["cx"] == nil {
		t.Errorf("serves = %v", got)
	}
}
