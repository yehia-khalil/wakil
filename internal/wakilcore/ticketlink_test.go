package wakilcore

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var iniKeys = []string{"INI"}

func TestBranchNameKey(t *testing.T) {
	if got := TicketKeysIn("ini-142-login", iniKeys); !reflect.DeepEqual(got, []string{"INI-142"}) {
		t.Fatalf("got %v", got)
	}
}

func TestNotAProjectKey(t *testing.T) {
	if got := TicketKeysIn("fix-UTF-8", iniKeys); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}

func TestNoProjectKeysInfersNothing(t *testing.T) {
	m, _ := MatchTickets("", "ini-142-login", 7, []string{"INI-5"}, 1, []string{"Ticket: INI-6"}, nil)
	if len(m) != 0 {
		t.Fatalf("got %v", m)
	}
	// a link made in Wakil still counts with no project keys
	m, _ = MatchTickets("INI-9", "x", 0, nil, 0, nil, nil)
	if len(m) != 1 || m[0].Key != "INI-9" || m[0].Source != "wakil" {
		t.Fatalf("got %v", m)
	}
}

func TestSeveralKeysFromOneSource(t *testing.T) {
	got := TicketKeysIn("ini-1 and INI-2, ini-1 again", iniKeys)
	if !reflect.DeepEqual(got, []string{"INI-1", "INI-2"}) {
		t.Fatalf("got %v", got)
	}
	got = TrailerKeys([]string{"x\n\nTicket: INI-3, INI-4", "INI-99 in prose\nticket: ini-5"}, iniKeys)
	if !reflect.DeepEqual(got, []string{"INI-3", "INI-4", "INI-5"}) {
		t.Fatalf("trailers got %v", got)
	}
}

func TestOrgProjectKeysAreTheOrgsOwn(t *testing.T) {
	localOrg(t)
	dir := t.TempDir()
	reg := map[string]ProjectEntry{}
	for name, key := range map[string]string{"api": "ini", "web": "INI", "ops": "ops", "bare": ""} {
		p := filepath.Join(dir, name+".json")
		proj := Project{Name: name, Org: "initech"}
		if key != "" {
			proj.Scopes.PM = &PMScope{Provider: "jira", ProjectKey: key}
		}
		if err := SaveProject(p, proj); err != nil {
			t.Fatal(err)
		}
		reg[name] = ProjectEntry{Path: p}
	}
	if err := SaveRegistry("initech", reg); err != nil {
		t.Fatal(err)
	}
	if got := OrgProjectKeys("initech"); !reflect.DeepEqual(got, []string{"INI", "OPS"}) {
		t.Fatalf("got %v", got)
	}
}

func TestWakilLinkOverridesInference(t *testing.T) {
	localOrg(t)
	repo := RepoKey("github.com", "initech", "api")
	if err := LinkTicket("initech", repo, "ini-142-login", "INI-200"); err != nil {
		t.Fatal(err)
	}
	link, ok := TicketLinkFor("initech", repo, "ini-142-login")
	if !ok || link != "INI-200" {
		t.Fatalf("got %q %v", link, ok)
	}
	m, _ := MatchTickets(link, "ini-142-login", 0, nil, 0, nil, iniKeys)
	if len(m) != 1 || m[0] != (TicketMatch{"INI-200", "wakil"}) {
		t.Fatalf("got %v", m)
	}
}

func TestUnlinkReturnsToInference(t *testing.T) {
	localOrg(t)
	repo := RepoKey("github.com", "initech", "api")
	LinkTicket("initech", repo, "ini-142-login", "INI-200")
	if err := LinkTicket("initech", repo, "ini-142-login", ""); err != nil {
		t.Fatal(err)
	}
	link, ok := TicketLinkFor("initech", repo, "ini-142-login")
	if ok {
		t.Fatalf("still linked to %q", link)
	}
	m, _ := MatchTickets(link, "ini-142-login", 0, nil, 0, nil, iniKeys)
	if len(m) != 1 || m[0] != (TicketMatch{"INI-142", "branch"}) {
		t.Fatalf("got %v", m)
	}
}

func TestFirstSourceMarkedAllShown(t *testing.T) {
	m, _ := MatchTickets("", "INI-1", 215, []string{"title", "closes INI-2 and INI-1"}, 0, nil, iniKeys)
	want := []TicketMatch{{"INI-1", "branch"}, {"INI-2", "pr"}}
	if !reflect.DeepEqual(m, want) {
		t.Fatalf("got %v", m)
	}
}

func TestLookedNamesEachSource(t *testing.T) {
	_, looked := MatchTickets("", "main-ish", 215, nil, 4, nil, iniKeys)
	want := []string{"branch name", "PR #215's title and body", "4 commits' trailers"}
	if !reflect.DeepEqual(looked, want) {
		t.Fatalf("got %v", looked)
	}
	_, looked = MatchTickets("", "x", 0, nil, 0, nil, iniKeys)
	if !reflect.DeepEqual(looked, []string{"branch name"}) {
		t.Fatalf("got %v", looked)
	}
}

func TestLongLivedFindsStagingAndProduction(t *testing.T) {
	prs := []PRHeadBase{{"ini-1", "staging"}, {"ini-1b", "production"}, {"ini-2", "ini-1"}}
	got := LongLivedBranches("main", prs, iniKeys)
	if !reflect.DeepEqual(got, []string{"main", "staging", "production"}) {
		t.Fatalf("got %v", got)
	}
}

func TestLinksKeyedByRepoAndBranch(t *testing.T) {
	localOrg(t)
	// two worktrees of one clone name the same remote, so they share the link
	a := RepoKey("github.com", "initech", "api")
	b := RepoKey("GitHub.com", "initech", "api")
	if a != "github.com/initech/api" || a != b {
		t.Fatalf("%q %q", a, b)
	}
	LinkTicket("initech", a, "feature", "INI-7")
	if k, ok := TicketLinkFor("initech", b, "feature"); !ok || k != "INI-7" {
		t.Fatalf("got %q %v", k, ok)
	}
	if _, ok := TicketLinkFor("initech", a, "other"); ok {
		t.Fatal("another branch is linked")
	}
	if _, ok := TicketLinkFor("initech", RepoKey("github.com", "initech", "web"), "feature"); ok {
		t.Fatal("another repo is linked")
	}
	org, _ := OrgDirFor("initech")
	if !strings.HasSuffix(filepath.Join(org, "tickets", "links.json"), "tickets/links.json") {
		t.Fatal()
	}
}
