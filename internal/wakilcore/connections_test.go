package wakilcore

import (
	"strings"
	"testing"
)

func connInput(kind string) MCPConnection {
	return MCPConnection{Kind: kind, Transport: "http", URL: "https://example.test/mcp", SignIn: "token"}
}

func TestAddConnectionNamesByKind(t *testing.T) {
	localOrg(t)
	a, err := AddConnection("initech", connInput("github"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := AddConnection("initech", connInput("github"))
	if err != nil {
		t.Fatal(err)
	}
	if a.Name != "github" || b.Name != "github-2" {
		t.Fatalf("names = %q, %q", a.Name, b.Name)
	}
	if got, ok := ConnectionFor("initech", "github-2"); !ok || got.Kind != "github" {
		t.Fatalf("ConnectionFor = %+v %v", got, ok)
	}
}

func TestAddConnectionRefusesReservedName(t *testing.T) {
	localOrg(t)
	c := connInput("custom")
	c.Name = "wakil-pm"
	_, err := AddConnection("initech", c)
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "reserved") {
		t.Fatalf("err = %v", err)
	}
}

func TestAddConnectionRefusesBadName(t *testing.T) {
	localOrg(t)
	c := connInput("custom")
	c.Name = "Git Hub"
	if _, err := AddConnection("initech", c); err == nil {
		t.Fatal("bad name accepted")
	} else if _, ok := IsUserError(err); !ok {
		t.Fatalf("not a UserError: %v", err)
	}
}

func TestAddConnectionRefusesADuplicateName(t *testing.T) {
	localOrg(t)
	c := connInput("custom")
	c.Name = "mine"
	if _, err := AddConnection("initech", c); err != nil {
		t.Fatal(err)
	}
	if _, err := AddConnection("initech", c); err == nil {
		t.Fatal("duplicate accepted")
	}
}

func TestRemoveConnectionDeletesItsSecret(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	c, err := AddConnection("initech", connInput("github"))
	if err != nil {
		t.Fatal(err)
	}
	if err := SetConnectionSecrets("initech", c.Name, map[string]string{"token": "t"}); err != nil {
		t.Fatal(err)
	}
	if err := RemoveConnection("initech", c.Name); err != nil {
		t.Fatal(err)
	}
	if _, ok := ConnectionFor("initech", c.Name); ok {
		t.Fatal("connection still there")
	}
	if _, err := SecretGetFor("initech", "conn:github"); err == nil {
		t.Fatal("secret still there")
	}
}

func TestSetConnectionSecretsMerges(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	c, err := AddConnection("initech", connInput("github"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := ConnectionSecrets("initech", c.Name); err != nil || len(got) != 0 {
		t.Fatalf("empty = %v %v", got, err)
	}
	if err := SetConnectionSecrets("initech", c.Name, map[string]string{"token": "a"}); err != nil {
		t.Fatal(err)
	}
	if err := SetConnectionSecrets("initech", c.Name, map[string]string{"site": "x"}); err != nil {
		t.Fatal(err)
	}
	got, err := ConnectionSecrets("initech", c.Name)
	if err != nil || got["token"] != "a" || got["site"] != "x" {
		t.Fatalf("secrets = %v %v", got, err)
	}
}

func TestRenameMovesTheSecret(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	c, err := AddConnection("initech", connInput("github"))
	if err != nil {
		t.Fatal(err)
	}
	if err := SetConnectionSecrets("initech", c.Name, map[string]string{"token": "a"}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateConnection("initech", "github", func(c *MCPConnection) { c.Name = "work-github" }); err != nil {
		t.Fatal(err)
	}
	got, err := ConnectionSecrets("initech", "work-github")
	if err != nil || got["token"] != "a" {
		t.Fatalf("new secrets = %v %v", got, err)
	}
	if old, err := ConnectionSecrets("initech", "github"); err != nil || len(old) != 0 {
		t.Fatalf("old secret left: %v", old)
	}
	if _, ok := ConnectionFor("initech", "github"); ok {
		t.Fatal("old name still listed")
	}
}

func TestToolAllowedFollowsHint(t *testing.T) {
	c := MCPConnection{Hints: map[string]string{"r": "readOnly", "w": "writes", "n": "", "d": "destructive"}}
	for tool, want := range map[string][2]bool{"r": {true, false}, "w": {false, false}, "n": {false, false}, "d": {false, true}, "unknown": {false, false}} {
		a, l := ToolAllowed(c, tool)
		if a != want[0] || l != want[1] {
			t.Errorf("%s = %v,%v want %v", tool, a, l, want)
		}
	}
}

func TestStoredSwitchBeatsHint(t *testing.T) {
	c := MCPConnection{
		Hints: map[string]string{"r": "readOnly", "w": "writes", "d": "destructive"},
		Allow: map[string]bool{"r": false, "w": true, "d": true},
	}
	if a, _ := ToolAllowed(c, "r"); a {
		t.Error("stored off lost to readOnly")
	}
	if a, _ := ToolAllowed(c, "w"); !a {
		t.Error("stored on lost to writes")
	}
	if a, l := ToolAllowed(c, "d"); a || !l {
		t.Errorf("locked tool = %v,%v", a, l)
	}
}

func TestSetConnectionAllowRefusesLocked(t *testing.T) {
	localOrg(t)
	c := connInput("custom")
	c.Name = "mine"
	c.Hints = map[string]string{"drop": "destructive", "list": "readOnly"}
	if _, err := AddConnection("initech", c); err != nil {
		t.Fatal(err)
	}
	if err := SetConnectionAllow("initech", "mine", "drop", true); err == nil {
		t.Fatal("locked tool switched on")
	}
	if err := SetConnectionAllow("initech", "mine", "list", false); err != nil {
		t.Fatal(err)
	}
	got, ok := ConnectionFor("initech", "mine")
	if !ok {
		t.Fatal("mine missing")
	}
	if got.Allow["list"] != false || len(got.Allow) != 1 {
		t.Fatalf("allow = %v", got.Allow)
	}
}

func TestConnectionNameIsAtMost32Characters(t *testing.T) {
	localOrg(t)
	c := connInput("custom")
	c.Name = strings.Repeat("a", 33)
	if _, err := AddConnection("initech", c); err == nil {
		t.Fatal("33-character name accepted")
	}
	c.Name = strings.Repeat("a", 32)
	if _, err := AddConnection("initech", c); err != nil {
		t.Fatalf("32-character name refused: %v", err)
	}
}

func TestResolvedConnectionURLExpandsFields(t *testing.T) {
	dd := MCPConnection{Kind: "datadog", URL: "https://mcp.{site}/api/unstable/mcp-server/mcp", Values: map[string]string{"site": "datadoghq.eu"}}
	if got := ResolvedConnectionURL(dd); got != "https://mcp.datadoghq.eu/api/unstable/mcp-server/mcp" {
		t.Fatalf("datadog = %q", got)
	}
	dd.Values = nil
	if got := ResolvedConnectionURL(dd); got != dd.URL {
		t.Fatalf("datadog with no site = %q, want the placeholder left for the error to show", got)
	}
}

func TestResolvedConnectionURLPicksAmplitudesRegion(t *testing.T) {
	amp := MCPConnection{Kind: "amplitude", URL: "https://mcp.amplitude.com/mcp", Values: map[string]string{"region": "eu"}}
	if got := ResolvedConnectionURL(amp); got != "https://mcp.eu.amplitude.com/mcp" {
		t.Fatalf("amplitude eu = %q", got)
	}
	amp.Values["region"] = "us"
	if got := ResolvedConnectionURL(amp); got != "https://mcp.amplitude.com/mcp" {
		t.Fatalf("amplitude us = %q", got)
	}
	amp = MCPConnection{Kind: "amplitude", URL: "https://proxy.example.test/mcp", Values: map[string]string{"region": "eu"}}
	if got := ResolvedConnectionURL(amp); got != "https://proxy.example.test/mcp" {
		t.Fatalf("an address the operator typed = %q, want it kept", got)
	}
}
