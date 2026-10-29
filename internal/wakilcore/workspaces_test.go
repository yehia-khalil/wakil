package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkspacesAbsentFileIsEmpty(t *testing.T) {
	setupHome(t)
	f, err := LoadWorkspaces("initech")
	if err != nil || len(f.Workspaces) != 0 {
		t.Fatalf("%+v %v", f, err)
	}
}

func TestWorkspacesRoundTrip(t *testing.T) {
	setupHome(t)
	path, err := WorkspaceCheckoutPath("initech", "estate", "fix-otp", "core")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(path, filepath.Join(".wakil", "orgs", "initech", "workspaces", "estate", "fix-otp", "core")) {
		t.Fatalf("path %q", path)
	}
	in := WorkspacesFile{Workspaces: []Workspace{{
		ID: "w1", Name: "Fix OTP guard order", Slug: "fix-otp", Project: "estate", Environment: "staging",
		Tickets: []string{"INI-142"}, Branch: "fix-otp",
		Checkouts: []WorkspaceCheckout{{Repo: "/p/core", Path: path, Branch: "fix-otp", Base: "main",
			Ports: &PortBlock{First: 41200, Count: 10}, LastHolder: "root-1"}},
		Conversations: []string{"root-1"}, View: "w1",
	}}}
	if err := SaveWorkspaces("initech", in); err != nil {
		t.Fatal(err)
	}
	out, err := LoadWorkspaces("initech")
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Workspaces) != 1 || out.Workspaces[0].Checkouts[0].Ports.First != 41200 || out.Workspaces[0].Tickets[0] != "INI-142" {
		t.Fatalf("%+v", out)
	}
}

func TestAnUnreadableWorkspacesFileIsRefusedWholeAndNeverWrittenOver(t *testing.T) {
	home, _ := setupHome(t)
	p := filepath.Join(home, ".wakil", "orgs", "initech", "workspaces.json")
	os.WriteFile(p, []byte("{not json"), 0o644)
	if _, err := LoadWorkspaces("initech"); err == nil || !strings.Contains(err.Error(), p) {
		t.Fatalf("load err %v", err)
	}
	if err := SaveWorkspaces("initech", WorkspacesFile{}); err == nil {
		t.Fatal("want refusal to write over an unreadable file")
	}
	if b, _ := os.ReadFile(p); string(b) != "{not json" {
		t.Fatalf("file changed: %q", b)
	}
}

func TestSaveRefusesACheckoutOutsideTheOrganisationsWorkspaces(t *testing.T) {
	setupHome(t)
	bad := WorkspacesFile{Workspaces: []Workspace{{ID: "w1", Slug: "s", Project: "p",
		Checkouts: []WorkspaceCheckout{{Repo: "/p/core", Path: "/tmp/elsewhere"}}}}}
	if err := SaveWorkspaces("initech", bad); err == nil {
		t.Fatal("want refusal")
	}
	dup := WorkspacesFile{Workspaces: []Workspace{{ID: "w1", Slug: "a"}, {ID: "w1", Slug: "b"}}}
	if err := SaveWorkspaces("initech", dup); err == nil {
		t.Fatal("want refusal of a duplicate id")
	}
}

func TestCheckoutPathRefusesSegmentsThatEscape(t *testing.T) {
	setupHome(t)
	for _, seg := range [][3]string{{"..", "s", "r"}, {"p", "a/b", "r"}, {"p", "s", ""}} {
		if _, err := WorkspaceCheckoutPath("initech", seg[0], seg[1], seg[2]); err == nil {
			t.Errorf("%v: want refusal", seg)
		}
	}
}

func TestAllowedRootsAddTheProjectsLiveCheckouts(t *testing.T) {
	setupHome(t)
	live, _ := WorkspaceCheckoutPath("initech", "estate", "a", "core")
	archived, _ := WorkspaceCheckoutPath("initech", "estate", "b", "core")
	other, _ := WorkspaceCheckoutPath("initech", "other", "c", "core")
	SaveWorkspaces("initech", WorkspacesFile{Workspaces: []Workspace{
		{ID: "a", Slug: "a", Project: "estate", Checkouts: []WorkspaceCheckout{{Repo: "/p/core", Path: live}, {Repo: "/p/web"}}},
		{ID: "b", Slug: "b", Project: "estate", Archived: true, Checkouts: []WorkspaceCheckout{{Repo: "/p/core", Path: archived}}},
		{ID: "c", Slug: "c", Project: "other", Checkouts: []WorkspaceCheckout{{Repo: "/p/core", Path: other}}},
	}})
	got := WorkspaceRootsFor("initech", "estate")
	if len(got) != 1 || got[0] != live {
		t.Fatalf("%v", got)
	}
	// An unreadable record adds nothing: Main's folders still answer.
	home, _ := os.UserHomeDir()
	os.WriteFile(filepath.Join(home, ".wakil", "orgs", "initech", "workspaces.json"), []byte("x"), 0o644)
	if got := WorkspaceRootsFor("initech", "estate"); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}
